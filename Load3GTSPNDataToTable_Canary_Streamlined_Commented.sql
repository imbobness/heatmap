USE [ManufacturingDB];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

/****** Object:  StoredProcedure [dbo].[Load3GTSPNDataToTable_Canary]    Script Date: 9/22/2026 10:39:42 AM ******/

/*****************************************************************************************************************
 Called From Job: getSPNData

 Author:	  Thure Hoeckelberg
 Create Date: 2022/12/05
 Description: Loads table tmpSPN3GTData --> SP: Shift3GTPredictNumbers --> 3GTShiftPredictNumbers.aspx 
			  Reworte to pull through dynamic cursor vice hard coded tags.

 SELECT *
 FROM SPN3GTData_Canary

 EXEC Load3GTSPNDataToTable_Canary
*******************************************************************************************************************/

/*
    Procedure: dbo.Load3GTSPNDataToTable_Canary

    Purpose:
      1. Retrieve current-hour and last-hour Canary values for active 3GT lines.
      2. Aggregate tag values into one row per production line.
      3. Calculate yields, shift projection, rates, and bypass values.
      4. Add previous-shift, lot, product, and business-plan information.
      5. Atomically refresh dbo.SPN3GTData_Canary.

    Called from SQL Agent job:
      getSPNData

    Important assumptions retained from the original:
      - Shift timing comes from maint_ProductionSchedule with DeptID = '2GT'.
      - Previous-shift production also uses the '2GT' schedule but
        shift_LensNumber.DeptID = '3GT'.
      - Missing ProductID defaults to 24.
      - Missing ShiftTarget defaults to 100000.
*/
ALTER PROCEDURE [dbo].[Load3GTSPNDataToTable_Canary]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        STREAMLINE CHANGE:
        Prevent overlapping SQL Agent/manual executions. Without this lock, two executions can both reach the
        destination refresh and temporarily expose an empty or inconsistent SPN3GTData_Canary table.
    */
    DECLARE @ApplicationLockResult INT;

    EXEC @ApplicationLockResult = sys.sp_getapplock
        @Resource = 'dbo.Load3GTSPNDataToTable_Canary',
        @LockMode = 'Exclusive',
        @LockOwner = 'Session',
        @LockTimeout = 0;

    IF @ApplicationLockResult < 0
    BEGIN
        SELECT
            'Skipped' AS RunStatus,
            'Another Load3GTSPNDataToTable_Canary execution is already running.' AS RunMessage;
        RETURN;
    END;

/*******************************************************************************************************************
 SET NOCOUNT ON - added to prevent extra result sets from interfering with SELECT statements.
 Declare variables and parameters 
*******************************************************************************************************************/

    DECLARE
        @EndDate            DATETIME,
        @ShiftStart         DATETIME,
        @ShiftEnd           DATETIME,
        @ShiftMinutes       FLOAT,
        @ShiftHours         FLOAT,
        @MinutesRemaining   FLOAT,
        @HoursRemaining     FLOAT,
        @PreviousProdDate   DATETIME,
        @PreviousTeamID     VARCHAR(50),
        @LotSQL             VARCHAR(MAX),

        @LineID             INT,
        @TagName            VARCHAR(MAX),
        @CurrentColumn      VARCHAR(150),
        @LastHourColumn     VARCHAR(150),
        @CurrentValue       FLOAT,
        @LastHourValue      FLOAT;

    /* STREAMLINE CHANGE: Ensure the application lock is released if historian, Oracle, or local SQL work fails. */
    BEGIN TRY

    /*******************************************************************************************************************
     Initialize variables and parameters

    *******************************************************************************************************************/

    /**********************************************************************
      1. Determine current shift timing
      STREAMLINE CHANGE: Read the schedule once and validate that a shift was found.
    **********************************************************************/
    SET @EndDate = GETDATE();

    SELECT
        @ShiftStart = MAX(ps.ShiftStart)
    FROM dbo.maint_ProductionSchedule AS ps
    WHERE ps.ShiftStart < @EndDate
      AND ps.DeptID = '2GT';

    IF @ShiftStart IS NULL
    BEGIN
        RAISERROR(
            'No active 2GT production schedule was found for the current time.',
            16,
            1
        );

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.Load3GTSPNDataToTable_Canary',
            @LockOwner = 'Session';
        RETURN;
    END;

    SET @ShiftEnd = DATEADD(HOUR, 12, @ShiftStart);

    SET @ShiftMinutes =
        CASE
            WHEN DATEDIFF(MINUTE, @ShiftStart, @EndDate) <= 0
                THEN 0.01
            WHEN DATEDIFF(MINUTE, @ShiftStart, @EndDate) > 720
                THEN 720.0
            ELSE CONVERT(FLOAT, DATEDIFF(MINUTE, @ShiftStart, @EndDate))
        END;

    SET @ShiftHours = @ShiftMinutes / 60.0;
    SET @MinutesRemaining =
        CASE
            WHEN 720.0 - @ShiftMinutes < 0 THEN 0
            ELSE 720.0 - @ShiftMinutes
        END;
    SET @HoursRemaining = @MinutesRemaining / 60.0;

    /**********************************************************************
      2. Temporary tables
    **********************************************************************/
    CREATE TABLE #TagValues
    (
        LineID          INT          NOT NULL,
        PeriodType      CHAR(1)      NOT NULL,
        ColumnName      VARCHAR(150) NOT NULL,
        TagName         VARCHAR(MAX) NOT NULL,
        TagValue        FLOAT        NULL
    );

    CREATE CLUSTERED INDEX IX_TagValues_Line_Period_Column
        ON #TagValues(LineID, PeriodType, ColumnName);

    CREATE TABLE #LotInfo
    (
        LotNumber       VARCHAR(30)  NULL,
        SKUInfo         VARCHAR(30)  NULL,
        ProductFamily   VARCHAR(150) NULL,
        Brand           VARCHAR(5)   NULL,
        ProductID       INT          NULL,
        LineID          INT          NOT NULL
    );

    CREATE CLUSTERED INDEX IX_LotInfo_LineID
        ON #LotInfo(LineID);

    CREATE TABLE #SPNData
    (
        LineID                  INT         NOT NULL,
        Line                    VARCHAR(20) NULL,

        FA_LastHourIn           FLOAT       NULL,
        FA_LastHourOut          FLOAT       NULL,
        FA_CurrentHourIn        FLOAT       NULL,
        FA_CurrentHourOut       FLOAT       NULL,

        DM_LastHourIn           FLOAT       NULL,
        DM_LastHourOut          FLOAT       NULL,
        DM_CurrentHourIn        FLOAT       NULL,
        DM_CurrentHourOut       FLOAT       NULL,

        HYD_LastHourIn          FLOAT       NULL,

        ALI_LastHourIn          FLOAT       NULL,
        ALI_LastHourOut         FLOAT       NULL,
        ALI_CurrentHourIn       FLOAT       NULL,
        ALI_CurrentHourOut      FLOAT       NULL,

        LoaderLastHour          FLOAT       NULL,
        LoaderCurrent           FLOAT       NULL,
        LotCountCurrent         FLOAT       NULL,

        FA_LastHourYield        DECIMAL(10,2) NULL,
        DM_LastHourYield        DECIMAL(10,2) NULL,
        ALI_LastHourYield       DECIMAL(10,2) NULL,

        ShiftPredict            INT           NULL,
        LoaderPreviousShift     INT           NULL,

        LotNumber               VARCHAR(30)   NULL,
        SpherePower             VARCHAR(30)   NULL,
        ProductID               INT           NULL,
        ShiftTarget             INT           NULL
    );

    CREATE UNIQUE CLUSTERED INDEX IX_SPNData_LineID
        ON #SPNData(LineID);

    /*******************************************************************************************************************
      Load current data into #tblSPN3GTCurrData table

     SELECT *
     FROM SPN3GTData_Canary

     EXEC Load3GTSPNDataToTable_Canary
    ********************************************************************************************************************/

    /*******************************************************************************************************************
    Load Last hour data into @#tblSPN3GTHourData table
    ********************************************************************************************************************/

    /**********************************************************************
      3. Retrieve current and last-hour Canary values

      One cursor is retained because the existing historian access is
      implemented through scalar functions that take one tag at a time.

      FAST_FORWARD reduces cursor overhead for this read-once operation.

      STREAMLINE CHANGE: The two original cursors are combined into one. Each configured tag is visited once,
      while the existing getCurrentValue_3GT and getHourlyValue_3GT functions remain unchanged.
    **********************************************************************/
    DECLARE TagCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT
            sp.LineID,
            sp.TagName,
            sp.Curr_Hour,
            sp.Last_Hour
        FROM dbo.maint_LineSPN_3GTCanaryTag AS sp
        INNER JOIN dbo.maint_Line AS ml
            ON ml.LineID = sp.LineID
        WHERE ml.ActiveInd = 'Y'
          AND ml.ProductionInd = 'Y'
          AND sp.ActiveInd = 'Y'
          AND sp.DeptID = '3GT';

    OPEN TagCursor;

    FETCH NEXT FROM TagCursor
    INTO
        @LineID,
        @TagName,
        @CurrentColumn,
        @LastHourColumn;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        /*
            Only call the current-value function when a current-hour
            destination column is configured.
        */
        IF NULLIF(LTRIM(RTRIM(@CurrentColumn)), '') IS NOT NULL
        BEGIN
            SET @CurrentValue =
                dbo.getCurrentValue_3GT(@TagName, @EndDate);

            INSERT INTO #TagValues
            (
                LineID,
                PeriodType,
                ColumnName,
                TagName,
                TagValue
            )
            VALUES
            (
                @LineID,
                'C',
                @CurrentColumn,
                @TagName,
                @CurrentValue
            );
        END;

        /*
            Only call the hourly-value function when a last-hour
            destination column is configured.
        */
        IF NULLIF(LTRIM(RTRIM(@LastHourColumn)), '') IS NOT NULL
        BEGIN
            SET @LastHourValue =
                dbo.getHourlyValue_3GT(@TagName, @EndDate);

            INSERT INTO #TagValues
            (
                LineID,
                PeriodType,
                ColumnName,
                TagName,
                TagValue
            )
            VALUES
            (
                @LineID,
                'H',
                @LastHourColumn,
                @TagName,
                @LastHourValue
            );
        END;

        FETCH NEXT FROM TagCursor
        INTO
            @LineID,
            @TagName,
            @CurrentColumn,
            @LastHourColumn;
    END;

    CLOSE TagCursor;
    DEALLOCATE TagCursor;

    /*******************************************************************************************************************
     Get initial data for #tblSPN3GTData table

    ********************************************************************************************************************/

    /*******************************************************************************************************************
     Update #tblSPN3GTData table with all attributes

     SELECT *
     FROM SPN3GTData_Canary

     EXEC Load3GTSPNDataToTable_Canary

    ********************************************************************************************************************/

    /**********************************************************************
      4. Aggregate all configured tag values into one row per line

      MAX(CASE...) replaces the original series of individual UPDATEs.
      STREAMLINE CHANGE: Values are pivoted in one grouped query instead of repeatedly scanning and updating
      the same temporary table for every output column.
    **********************************************************************/
    ;WITH AggregatedTags AS
    (
        SELECT
            tv.LineID,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'FA_LAST_HR_IN'
                    THEN tv.TagValue
                END) AS FA_LastHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'FA_LAST_HR'
                    THEN tv.TagValue
                END) AS FA_LastHourOut,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'FA_CURR_IN'
                    THEN tv.TagValue
                END) AS FA_CurrentHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'FA_CURR'
                    THEN tv.TagValue
                END) AS FA_CurrentHourOut,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'DM_LAST_HR_IN'
                    THEN tv.TagValue
                END) AS DM_LastHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'DM_LAST_HR'
                    THEN tv.TagValue
                END) AS DM_LastHourOut,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'DM_CURR_IN'
                    THEN tv.TagValue
                END) AS DM_CurrentHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'DM_CURR'
                    THEN tv.TagValue
                END) AS DM_CurrentHourOut,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'HYD_LAST_HR_IN'
                    THEN tv.TagValue
                END) AS HYD_LastHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'ALI_YIELD_LAST_In'
                    THEN tv.TagValue
                END) AS ALI_LastHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'ALI_YIELD_LAST_Out'
                    THEN tv.TagValue
                END) AS ALI_LastHourOut,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'ALI_YIELD_CURR_In'
                    THEN tv.TagValue
                END) AS ALI_CurrentHourIn,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'ALI_YIELD_CURR_Out'
                    THEN tv.TagValue
                END) AS ALI_CurrentHourOut,

            MAX(CASE
                    WHEN tv.PeriodType = 'H'
                     AND tv.ColumnName = 'Loader_LAST_HR'
                    THEN tv.TagValue
                END) AS LoaderLastHour,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'Loader_CURR'
                    THEN tv.TagValue
                END) AS LoaderCurrent,

            MAX(CASE
                    WHEN tv.PeriodType = 'C'
                     AND tv.ColumnName = 'LOT_COUNT_CURR'
                    THEN tv.TagValue
                END) AS LotCountCurrent
        FROM #TagValues AS tv
        GROUP BY
            tv.LineID
    )
    INSERT INTO #SPNData
    (
        LineID,
        Line,

        FA_LastHourIn,
        FA_LastHourOut,
        FA_CurrentHourIn,
        FA_CurrentHourOut,

        DM_LastHourIn,
        DM_LastHourOut,
        DM_CurrentHourIn,
        DM_CurrentHourOut,

        HYD_LastHourIn,

        ALI_LastHourIn,
        ALI_LastHourOut,
        ALI_CurrentHourIn,
        ALI_CurrentHourOut,

        LoaderLastHour,
        LoaderCurrent,
        LotCountCurrent,

        FA_LastHourYield,
        DM_LastHourYield,
        ALI_LastHourYield,

        ShiftPredict
    )
    SELECT
        ml.LineID,
        ml.CribmasterLineID,

        at.FA_LastHourIn,
        at.FA_LastHourOut,
        at.FA_CurrentHourIn,
        at.FA_CurrentHourOut,

        at.DM_LastHourIn,
        at.DM_LastHourOut,
        at.DM_CurrentHourIn,
        at.DM_CurrentHourOut,

        at.HYD_LastHourIn,

        at.ALI_LastHourIn,
        at.ALI_LastHourOut,
        at.ALI_CurrentHourIn,
        at.ALI_CurrentHourOut,

        at.LoaderLastHour,
        at.LoaderCurrent,
        at.LotCountCurrent,

        /*
            Yield is capped at 100 percent.
            NULLIF prevents divide-by-zero errors.
        */
        CONVERT
        (
            DECIMAL(10,2),
            CASE
                WHEN ISNULL(at.FA_LastHourIn, 0) <= 0 THEN 0
                WHEN (ISNULL(at.FA_LastHourOut, 0) * 100.0)
                     / NULLIF(at.FA_LastHourIn, 0) > 100
                    THEN 100
                ELSE (ISNULL(at.FA_LastHourOut, 0) * 100.0)
                     / NULLIF(at.FA_LastHourIn, 0)
            END
        ) AS FA_LastHourYield,

        CONVERT
        (
            DECIMAL(10,2),
            CASE
                WHEN ISNULL(at.DM_LastHourIn, 0) <= 0 THEN 0
                WHEN (ISNULL(at.DM_LastHourOut, 0) * 100.0)
                     / NULLIF(at.DM_LastHourIn, 0) > 100
                    THEN 100
                ELSE (ISNULL(at.DM_LastHourOut, 0) * 100.0)
                     / NULLIF(at.DM_LastHourIn, 0)
            END
        ) AS DM_LastHourYield,

        CONVERT
        (
            DECIMAL(10,2),
            CASE
                WHEN ISNULL(at.ALI_LastHourIn, 0) <= 0 THEN 0
                WHEN (ISNULL(at.ALI_LastHourOut, 0) * 100.0)
                     / NULLIF(at.ALI_LastHourIn, 0) > 100
                    THEN 100
                ELSE (ISNULL(at.ALI_LastHourOut, 0) * 100.0)
                     / NULLIF(at.ALI_LastHourIn, 0)
            END
        ) AS ALI_LastHourYield,

        CONVERT
        (
            INT,
            CASE
                WHEN ISNULL(at.LoaderCurrent, 0) <= 0 THEN 0
                ELSE
                    at.LoaderCurrent
                    + (
                        at.LoaderCurrent
                        / NULLIF(@ShiftHours, 0)
                      ) * @HoursRemaining
            END
        ) AS ShiftPredict
    FROM dbo.maint_Line AS ml
    /*
        COMPATIBILITY CHANGE: Keep the original behavior of returning only lines represented by configured
        historian data. A LEFT JOIN here would add active lines that the original loader never produced.
    */
    INNER JOIN AggregatedTags AS at
        ON at.LineID = ml.LineID
    WHERE ml.ActiveInd = 'Y'
      AND ml.ProductionInd = 'Y'
      AND ml.DeptID = '3GT';

    /**********************************************************************
      5. Retrieve the previous completed shift once

      The original procedure repeated the same ProductionSchedule lookup
      for ProductionDate and TeamID.
    **********************************************************************/
    SELECT TOP (1)
        @PreviousProdDate = ps.ProductionDate,
        @PreviousTeamID = ps.TeamID
    FROM dbo.maint_ProductionSchedule AS ps
    WHERE ps.ShiftEnd >= DATEADD(HOUR, -12, @EndDate)
      AND ps.ShiftEnd <= @EndDate
      AND ps.DeptID = '2GT'
    ORDER BY
        ps.ShiftEnd DESC;

    UPDATE spn
    SET
        spn.LoaderPreviousShift = sln.LensPerShift
    FROM #SPNData AS spn
    INNER JOIN dbo.shift_LensNumber AS sln
        ON sln.LineID = spn.LineID
       AND sln.ProductionDate = @PreviousProdDate
       AND sln.TeamID = @PreviousTeamID
       AND sln.DeptID = '3GT';

    /*******************************************************************************************************************
     Get Lot numbers
    ********************************************************************************************************************/

    /**********************************************************************
      6. Retrieve active 3GT lot and product information

      The OPENQUERY logic is retained because the remote MNFDB_P3GT
      source contains Oracle-specific syntax.
    **********************************************************************/
    SET @LotSQL =
        'SELECT
             remoteLot.containername,
             remoteLot.spherepower,
             CASE
                 WHEN remoteLot.prodfam LIKE ''1D MOIST MULTIFOCAL%''
                     THEN ''1DM Multifocal''
                 WHEN remoteLot.prodfam LIKE ''1DM ASTIG%''
                     THEN ''1DM Astigmatism''
                 ELSE remoteLot.prodfam
             END AS ProductFamily,
             remoteLot.Brand,
             product.ProductID,
             line.LineID
         FROM OPENQUERY
         (
             MNFDB_P3GT,
             ''
                 SELECT *
                 FROM
                 (
                     SELECT
                         ld.lot_no AS containername,
                         CASE
                             WHEN pr.cylinder IS NOT NULL
                                 THEN TO_CHAR
                                 (
                                     pr.Base_Curve || '''' '''' ||
                                     pr.sphere_power || '''' '''' ||
                                     pr.cylinder || ''''/'''' ||
                                     pr.axis
                                 )
                             WHEN pr.add_power IS NOT NULL
                                 THEN TO_CHAR
                                 (
                                     pr.Base_Curve || '''' '''' ||
                                     pr.sphere_power || '''' / '''' ||
                                     pr.add_power
                                 )
                             ELSE
                                 pr.Base_Curve || '''' '''' ||
                                 pr.sphere_power
                         END AS spherepower,
                         pr.prod_desc AS prodfam,
                         pr.BRAND,
                         ld.lsmachine_no
                     FROM OWNER_3GT.LOT_DATA ld
                     INNER JOIN OWNER_3GT.S_PROD_ID_MASTER pr
                         ON pr.product_id = ld.product_id
                     WHERE ld.lot_status = ''''IN-PROCESS''''
                       AND ld.lc_datetime IS NULL
                       AND ld.capture_datetime =
                           (
                               SELECT MAX(x.capture_datetime)
                               FROM lot_data x
                               WHERE x.lsmachine_no = ld.lsmachine_no
                                 AND x.lot_status = ''''IN-PROCESS''''
                                 AND x.lc_datetime IS NULL
                           )
                 )
             ''
         ) AS remoteLot
         INNER JOIN ManufacturingDB.dbo.maint_Line AS line
             ON line.ODSPLineName = remoteLot.lsmachine_no
         LEFT JOIN ManufacturingDB.dbo.maint_Product AS product
             ON product.Brand = remoteLot.Brand
         WHERE line.ProductionInd = ''Y''
           AND line.DeptID = ''3GT'';';

    INSERT INTO #LotInfo
    (
        LotNumber,
        SKUInfo,
        ProductFamily,
        Brand,
        ProductID,
        LineID
    )
    EXEC (@LotSQL);

/*******************************************************************************************************************
Update tblSPN2GTData with lot data Z18_MES_LOT_NUMBER, Z18_LOT_POWER, Z18_PROD_ID
		EXEC Load3GTSPNDataToTable
*******************************************************************************************************************/

    /*
        If multiple remote rows resolve to one line, use one grouped record
        so the UPDATE cannot return multiple matches for the same LineID.
    */
    ;WITH LotByLine AS
    (
        SELECT
            li.LineID,
            MAX(li.LotNumber) AS LotNumber,
            MAX(li.SKUInfo) AS SKUInfo,
            MAX(li.ProductID) AS ProductID
        FROM #LotInfo AS li
        GROUP BY
            li.LineID
    )
    UPDATE spn
    SET
        spn.LotNumber = lot.LotNumber,
        spn.SpherePower = lot.SKUInfo,
        spn.ProductID = lot.ProductID
    FROM #SPNData AS spn
    INNER JOIN LotByLine AS lot
        ON lot.LineID = spn.LineID;

    /*******************************************************************************************************************
	Catch Errors teset and Increment the Tag Loop Count
    *******************************************************************************************************************/

    /*******************************************************************************************************************
	We first remove unwanted lines and update targets for all lines running engineering lots or in middle of master
	lot change or that has productID of 24 to 100000 then we update the ShiftTargt columns for maximum recordId
	for each line from maint_BusinessPlan.
    *******************************************************************************************************************/

    /**********************************************************************
      7. Apply product defaults and business-plan target

      ProductID 24 remains the fallback used by the original procedure.
    **********************************************************************/
    UPDATE #SPNData
    SET
        ProductID = ISNULL(ProductID, 24),
        ShiftTarget = 100000;

    /*
        Select the greatest RecordID for the active year/month,
        line, and product. This implements the intent documented in
        the original comments.
    */
    ;WITH CurrentProductionPeriod AS
    (
        SELECT MAX(pym.RecordID) AS RecordID
        FROM dbo.maint_ProductionYearMonth AS pym
        WHERE @EndDate BETWEEN pym.MonthStartDate AND pym.MonthEndDate
    ),
    LatestBusinessPlan AS
    (
        SELECT
            bp.LineID,
            bp.ProductID,
            bp.BusinessPlan,
            ROW_NUMBER() OVER
            (
                PARTITION BY
                    bp.LineID,
                    bp.ProductID
                ORDER BY
                    bp.RecordID DESC
            ) AS RowNumber
        FROM dbo.maint_BusinessPlan AS bp
        CROSS JOIN CurrentProductionPeriod AS cpp
        WHERE bp.MaintProductionYearMonthRecordID = cpp.RecordID
    )
    UPDATE spn
    SET
        spn.ShiftTarget = ISNULL(bp.BusinessPlan, 0)
    FROM #SPNData AS spn
    INNER JOIN LatestBusinessPlan AS bp
        ON bp.LineID = spn.LineID
       AND bp.ProductID = spn.ProductID
       AND bp.RowNumber = 1
    WHERE spn.ProductID <> 24;

    /*******************************************************************************************************************
	Check if temp table has data, if data present truncate SPN3GTData table and insert new data
     SELECT *
     FROM SPN3GTData_Canary

     EXEC Load3GTSPNDataToTable_Canary
    *******************************************************************************************************************/

    /**********************************************************************
      8. Safety validation before refreshing the production table
    **********************************************************************/
    IF NOT EXISTS
    (
        SELECT 1
        FROM #SPNData
    )
    BEGIN
        RAISERROR(
            'No 3GT SPN data was generated. SPN3GTData_Canary was not refreshed.',
            16,
            1
        );

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.Load3GTSPNDataToTable_Canary',
            @LockOwner = 'Session';
        RETURN;
    END;

    /**********************************************************************
      9. Atomically refresh the destination table
    **********************************************************************/
    BEGIN TRY
        BEGIN TRANSACTION;

        TRUNCATE TABLE dbo.SPN3GTData_Canary;

        INSERT INTO dbo.SPN3GTData_Canary
        (
            SortOrder,
            ShiftStartDate,
            ShiftEndDate,
            Date,
            MinElapsed,
            HrElapsed,
            MinRemain,
            HrRemain,
            Line,
            FA_LastHr,
            FA_LastHrYld,
            DM_LastHr,
            DM_LastHrYld,
            HYD_LastHrBypass,
            ALI_LastHourYield,
            ShiftPredict,
            Loader_PreviousShift,
            Post_OutCurr,
            Loader_AveHrlyRate,
            Post_OutLastHour,
            Loader_LotNumber,
            Loader_Power,
            Loader_RackCount,
            ShiftTarget,
            Prod_ID
        )
        SELECT
            spn.LineID AS SortOrder,
            @ShiftStart AS ShiftStartDate,
            @ShiftEnd AS ShiftEndDate,
            @EndDate AS Date,
            @ShiftMinutes AS MinElapsed,
            @ShiftHours AS HrElapsed,
            @MinutesRemaining AS MinRemain,
            @HoursRemaining AS HrRemain,
            spn.Line,

            CONVERT(INT, ISNULL(spn.FA_LastHourOut, 0)) AS FA_LastHr,
            ISNULL(spn.FA_LastHourYield, 0) AS FA_LastHrYld,

            CONVERT(INT, ISNULL(spn.DM_LastHourOut, 0)) AS DM_LastHr,
            ISNULL(spn.DM_LastHourYield, 0) AS DM_LastHrYld,

            CONVERT
            (
                INT,
                ISNULL(spn.DM_LastHourOut, 0)
                - ISNULL(spn.HYD_LastHourIn, 0)
            ) AS HYD_LastHrBypass,

            ISNULL(spn.ALI_LastHourYield, 0) AS ALI_LastHourYield,
            ISNULL(spn.ShiftPredict, 0) AS ShiftPredict,
            ISNULL(spn.LoaderPreviousShift, 0) AS Loader_PreviousShift,

            CONVERT(INT, ISNULL(spn.LoaderCurrent, 0)) AS Post_OutCurr,

            CONVERT
            (
                FLOAT,
                ISNULL(spn.LoaderCurrent, 0)
                / NULLIF(@ShiftHours, 0)
            ) AS Loader_AveHrlyRate,

            CONVERT(INT, ISNULL(spn.LoaderLastHour, 0))
                AS Post_OutLastHour,

            ISNULL(spn.LotNumber, '24') AS Loader_LotNumber,
            spn.SpherePower AS Loader_Power,

            CONVERT(INT, ISNULL(spn.LotCountCurrent, 0))
                AS Loader_RackCount,

            ISNULL(spn.ShiftTarget, 100000) AS ShiftTarget,
            ISNULL(spn.ProductID, 24) AS Prod_ID
        FROM #SPNData AS spn;

        COMMIT TRANSACTION;

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.Load3GTSPNDataToTable_Canary',
            @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.Load3GTSPNDataToTable_Canary',
            @LockOwner = 'Session';

        DECLARE
            @ErrorMessage  NVARCHAR(4000),
            @ErrorSeverity INT,
            @ErrorState    INT;

        SELECT
            @ErrorMessage = ERROR_MESSAGE(),
            @ErrorSeverity = ERROR_SEVERITY(),
            @ErrorState = ERROR_STATE();

        RAISERROR
        (
            @ErrorMessage,
            @ErrorSeverity,
            @ErrorState
        );
    END CATCH;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.Load3GTSPNDataToTable_Canary',
            @LockOwner = 'Session';

        THROW;
    END CATCH;
END;
GO
