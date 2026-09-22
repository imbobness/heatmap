USE [ManufacturingDB];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/*
    Drop-in SSMS replacement for dbo.HeatMap3GTLast48HoursLoader_Canary.

    Important compatibility choices:
      - Keeps the ORIGINAL procedure name, so the existing SQL Agent job/caller still works.
      - Defaults to 48 hours, not 180 hours.
      - Keeps TagValue as FLOAT.
      - Calls dbo.TagValue_Canary positionally, matching the working procedure.
      - Stages Canary values first and inserts only after lot metadata is available.
      - Does not convert NULL/missing historian values into false zero-production values.

    Normal run:
      EXEC dbo.HeatMap3GTLast48HoursLoader_Canary;

    Fill any missing rows in the last 48 hours:
      EXEC dbo.HeatMap3GTLast48HoursLoader_Canary
          @HoursBack = 48,
          @ReloadExisting = 0;

    Rebuild the last 48 hours after changing tag configuration:
      EXEC dbo.HeatMap3GTLast48HoursLoader_Canary
          @HoursBack = 48,
          @ReloadExisting = 1;
*/
ALTER PROCEDURE [dbo].[HeatMap3GTLast48HoursLoader_Canary]
    @HoursBack SMALLINT = 48,
    @ReloadExisting BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @LastHour SMALLDATETIME,
        @FirstHour SMALLDATETIME,
        @LineID TINYINT,
        @DateTimeFrom SMALLDATETIME,
        @DateTimeTo SMALLDATETIME,
        @TagName VARCHAR(500),
        @TagValue FLOAT,
        @ErrorLocation VARCHAR(30) = 'Startup',
        @ApplicationLockResult INT,
        @WorkItems INT = 0,
        @RowsInserted INT = 0,
        @RowsDeleted INT = 0;

    IF @HoursBack IS NULL OR @HoursBack < 1 OR @HoursBack > 180
        THROW 50001, '@HoursBack must be between 1 and 180.', 1;

    EXEC @ApplicationLockResult = sys.sp_getapplock
        @Resource = 'dbo.HeatMap3GTLast48HoursLoader_Canary',
        @LockMode = 'Exclusive',
        @LockOwner = 'Session',
        @LockTimeout = 0;

    IF @ApplicationLockResult < 0
    BEGIN
        SELECT
            'Skipped' AS RunStatus,
            'Another heat-map loader execution is already running.' AS RunMessage;
        RETURN;
    END;

    BEGIN TRY
        SET @LastHour = DATEADD(HOUR, DATEDIFF(HOUR, 0, GETDATE()), 0);
        SET @FirstHour = DATEADD(HOUR, -@HoursBack, @LastHour);

        CREATE TABLE #TimeArray
        (
            DateTimeFrom SMALLDATETIME NOT NULL PRIMARY KEY,
            DateTimeTo SMALLDATETIME NOT NULL
        );

        ;WITH Hours AS
        (
            SELECT TOP (@HoursBack)
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS HourNumber
            FROM sys.all_columns AS a
            CROSS JOIN sys.all_columns AS b
        )
        INSERT INTO #TimeArray (DateTimeFrom, DateTimeTo)
        SELECT
            DATEADD(HOUR, -HourNumber, @LastHour),
            DATEADD(HOUR, -HourNumber + 1, @LastHour)
        FROM Hours;

        CREATE TABLE #WorkQueue
        (
            WorkID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
            LineID TINYINT NOT NULL,
            TagName VARCHAR(500) NOT NULL,
            DateTimeFrom SMALLDATETIME NOT NULL,
            DateTimeTo SMALLDATETIME NOT NULL
        );

        SET @ErrorLocation = 'WorkQueue';

        INSERT INTO #WorkQueue (LineID, TagName, DateTimeFrom, DateTimeTo)
        SELECT
            configured.LineID,
            configured.TagName,
            period.DateTimeFrom,
            period.DateTimeTo
        FROM
        (
            SELECT DISTINCT tags.LineID, tags.TagName
            FROM dbo.maint_3GTHeatMapTags_Canary AS tags
            INNER JOIN dbo.maint_Line AS productionLine
                ON productionLine.LineID = tags.LineID
            WHERE productionLine.ProductionInd = 'Y'
        ) AS configured
        CROSS JOIN #TimeArray AS period
        WHERE @ReloadExisting = 1
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.heatMap3GTLast48Hours_Canary AS existing
                  WHERE existing.LineID = configured.LineID
                    AND existing.TagName = configured.TagName
                    AND existing.DateTimeFrom = period.DateTimeFrom
              );

        SET @WorkItems = @@ROWCOUNT;

        CREATE INDEX IX_WorkQueue_Order
            ON #WorkQueue (DateTimeFrom DESC, LineID, TagName);

        CREATE TABLE #HeatMapValues
        (
            LineID TINYINT NOT NULL,
            TagName VARCHAR(500) NOT NULL,
            DateTimeFrom SMALLDATETIME NOT NULL,
            DateTimeTo SMALLDATETIME NOT NULL,
            TagValue FLOAT NULL
        );

        SET @ErrorLocation = 'CanaryLoad';

        DECLARE CanaryHeatMapCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT LineID, TagName, DateTimeFrom, DateTimeTo
            FROM #WorkQueue
            ORDER BY DateTimeFrom DESC, LineID, TagName;

        OPEN CanaryHeatMapCursor;

        FETCH NEXT FROM CanaryHeatMapCursor
        INTO @LineID, @TagName, @DateTimeFrom, @DateTimeTo;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @TagValue = NULL;

            /* Preserve the positional call used by the working original procedure. */
            EXEC @TagValue = dbo.TagValue_Canary
                @DateTimeFrom,
                @DateTimeTo,
                @TagName;

            INSERT INTO #HeatMapValues
                (LineID, TagName, DateTimeFrom, DateTimeTo, TagValue)
            VALUES
                (@LineID, @TagName, @DateTimeFrom, @DateTimeTo, @TagValue);

            FETCH NEXT FROM CanaryHeatMapCursor
            INTO @LineID, @TagName, @DateTimeFrom, @DateTimeTo;
        END;

        CLOSE CanaryHeatMapCursor;
        DEALLOCATE CanaryHeatMapCursor;

        CREATE TABLE #OracleLots
        (
            LotRowID INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
            LineName VARCHAR(50) NULL,
            LotNum VARCHAR(10) NULL,
            LotStartDate SMALLDATETIME NULL,
            ProductID VARCHAR(10) NULL,
            Brand VARCHAR(10) NULL,
            SpherePower VARCHAR(25) NULL
        );

        SET @ErrorLocation = 'OracleLots';

        INSERT INTO #OracleLots
            (LineName, LotNum, LotStartDate, ProductID, Brand, SpherePower)
        SELECT LineName, LotNum, LotStartDate, ProductID, Brand, SpherePower
        FROM OPENQUERY
        (
            MNFDB_P3GT,
            'SELECT la.LSMACHINE_NO AS LineName,
                    la.LOT_NO AS LotNum,
                    la.LS_DATETIME AS LotStartDate,
                    la.PRODUCT_ID AS ProductID,
                    spidm.BRAND AS Brand,
                    CASE
                        WHEN spidm.cylinder IS NOT NULL
                            THEN TO_CHAR(spidm.Base_Curve||'' ''||spidm.sphere_power||'' ''||spidm.cylinder||''/''||spidm.axis)
                        WHEN spidm.add_power IS NOT NULL
                            THEN TO_CHAR(spidm.Base_Curve||'' ''||spidm.sphere_power||'' / ''||spidm.add_power)
                        ELSE spidm.Base_Curve||'' ''||spidm.sphere_power
                    END AS SpherePower
             FROM OWNER_3GT.LOT_DATA la
             INNER JOIN OWNER_3GT.S_PROD_ID_MASTER spidm
                 ON la.PRODUCT_ID = spidm.PRODUCT_ID
             WHERE la.LS_DATETIME > SYSDATE-6
               AND la.LSMACHINE_NO NOT LIKE ''LINE%''
               AND la.LOT_STATUS = ''IN-PROCESS'''
        );

        CREATE TABLE #LotRanges
        (
            LineID TINYINT NOT NULL,
            LotStartDate SMALLDATETIME NOT NULL,
            LotEndDate SMALLDATETIME NOT NULL,
            Brand VARCHAR(10) NULL,
            SpherePower VARCHAR(25) NULL
        );

        ;WITH OrderedLots AS
        (
            SELECT
                LineName,
                LotStartDate,
                Brand,
                SpherePower,
                LEAD(LotStartDate) OVER
                    (PARTITION BY LineName ORDER BY LotStartDate, LotRowID) AS NextLotStartDate
            FROM #OracleLots
        )
        INSERT INTO #LotRanges
            (LineID, LotStartDate, LotEndDate, Brand, SpherePower)
        SELECT
            productionLine.LineID,
            lot.LotStartDate,
            ISNULL(lot.NextLotStartDate, GETDATE()),
            lot.Brand,
            lot.SpherePower
        FROM OrderedLots AS lot
        INNER JOIN dbo.maint_Line AS productionLine
            ON lot.LineName = SUBSTRING(UPPER(productionLine.LineName), 5, 10)
        WHERE productionLine.ProductionInd = 'Y';

        CREATE INDEX IX_LotRanges_Match
            ON #LotRanges (LineID, LotStartDate, LotEndDate);

        SET @ErrorLocation = 'FinalInsert';

        BEGIN TRANSACTION;

        DELETE FROM dbo.heatMap3GTLast48Hours_Canary
        WHERE DateTimeFrom < DATEADD(HOUR, -180, @LastHour);

        SET @RowsDeleted = @@ROWCOUNT;

        IF @ReloadExisting = 1
        BEGIN
            DELETE target
            FROM dbo.heatMap3GTLast48Hours_Canary AS target
            INNER JOIN dbo.maint_Line AS productionLine
                ON productionLine.LineID = target.LineID
            WHERE productionLine.ProductionInd = 'Y'
              AND target.DateTimeFrom >= @FirstHour
              AND target.DateTimeFrom < @LastHour;

            SET @RowsDeleted += @@ROWCOUNT;
        END;

        INSERT INTO dbo.heatMap3GTLast48Hours_Canary
            (LineID, TagName, DateTimeFrom, DateTimeTo, TagValue, Brand, SpherePower)
        SELECT
            valuesToLoad.LineID,
            valuesToLoad.TagName,
            valuesToLoad.DateTimeFrom,
            valuesToLoad.DateTimeTo,
            valuesToLoad.TagValue,
            lot.Brand,
            lot.SpherePower
        FROM #HeatMapValues AS valuesToLoad
        INNER JOIN #LotRanges AS lot
            ON lot.LineID = valuesToLoad.LineID
           AND valuesToLoad.DateTimeFrom >= lot.LotStartDate
           AND valuesToLoad.DateTimeFrom < lot.LotEndDate
        WHERE @ReloadExisting = 1
           OR NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.heatMap3GTLast48Hours_Canary AS existing WITH (UPDLOCK, HOLDLOCK)
                  WHERE existing.LineID = valuesToLoad.LineID
                    AND existing.TagName = valuesToLoad.TagName
                    AND existing.DateTimeFrom = valuesToLoad.DateTimeFrom
              );

        SET @RowsInserted = @@ROWCOUNT;

        COMMIT TRANSACTION;

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.HeatMap3GTLast48HoursLoader_Canary',
            @LockOwner = 'Session';

        SELECT
            'Completed' AS RunStatus,
            @HoursBack AS HoursRequested,
            @WorkItems AS CanaryCalls,
            @RowsInserted AS RowsInserted,
            @RowsDeleted AS RowsDeleted,
            @FirstHour AS WindowStart,
            @LastHour AS WindowEnd;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'CanaryHeatMapCursor') >= 0
            CLOSE CanaryHeatMapCursor;

        IF CURSOR_STATUS('local', 'CanaryHeatMapCursor') > -3
            DEALLOCATE CanaryHeatMapCursor;

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage VARCHAR(1000) = LEFT(ERROR_MESSAGE(), 1000);

        INSERT INTO dbo.maint_Error ([date], [description], [location])
        VALUES
        (
            GETDATE(),
            @ErrorMessage,
            'HeatMap3GTLast48HoursLoader_Canary; ' + @ErrorLocation
        );

        EXEC sys.sp_releaseapplock
            @Resource = 'dbo.HeatMap3GTLast48HoursLoader_Canary',
            @LockOwner = 'Session';

        THROW;
    END CATCH;
END;
GO

/*
    First test after deployment (small and safe):

    EXEC dbo.HeatMap3GTLast48HoursLoader_Canary
        @HoursBack = 2,
        @ReloadExisting = 0;

    SELECT TOP (200) *
    FROM dbo.heatMap3GTLast48Hours_Canary
    ORDER BY DateTimeFrom DESC, LineID, TagName;
*/
