USE [ManufacturingDB]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/***************************************************************************************************************
Author: Valeriy Yakovelv
Original date: 02/06/2015
Updated by: Robert Dees
Updated date: 09/10/2026

Description:
    Loads Canary heat-map values into dbo.heatMap3GTLast48Hours_Canary and updates lot metadata.

2026 improvements:
    1. Prevents overlapping executions with sp_getapplock.
    2. Supports small incremental runs with @HoursBack and complete reloads with @ReloadExisting.
    3. Replaces INFORMATION_SCHEMA.TABLES row generation with a deterministic temporary number table.
    4. Replaces the table-variable work source with an indexed temporary work queue.
    5. Processes newest missing hours first so current dashboard data is prioritized.
    6. Keeps remote Canary and Oracle calls outside local transactions.
    7. Replaces identity/self-join lot-range logic with LEAD.
    8. Updates Brand and SpherePower only when values changed.
    9. Adds detailed error context including LineID, tag, and hour.
   10. Returns a compact execution summary.

Normal incremental execution:
    EXEC dbo.HeatMap3GTLast48HoursLoader_Canary_RobertDees
        @HoursBack = 2,
        @ReloadExisting = 0;

Validate or backfill missing records across the current 48-hour window:
    EXEC dbo.HeatMap3GTLast48HoursLoader_Canary_RobertDees
        @HoursBack = 48,
        @ReloadExisting = 0;

Force a full 48-hour rebuild after correcting tag mappings:
    EXEC dbo.HeatMap3GTLast48HoursLoader_Canary_RobertDees
        @HoursBack = 48,
        @ReloadExisting = 1;
***************************************************************************************************************/
CREATE OR ALTER PROCEDURE [dbo].[HeatMap3GTLast48HoursLoader_Canary_RobertDees]
    @HoursBack SMALLINT = 48,
    @ReloadExisting BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @ProcedureName SYSNAME = 'dbo.HeatMap3GTLast48HoursLoader_Canary_RobertDees',
        @ErrorLocation VARCHAR(30) = 'Startup',
        @LastHour SMALLDATETIME,
        @FirstHour SMALLDATETIME,
        @LineID TINYINT,
        @DateTimeFrom SMALLDATETIME,
        @DateTimeTo SMALLDATETIME,
        @TagName VARCHAR(500),
        @TagValue INT,
        @RowsInserted INT = 0,
        @RowsDeleted INT = 0,
        @BrandRowsUpdated INT = 0,
        @WorkItems INT = 0,
        @ApplicationLockResult INT;

    /***********************************************************************************************************
        IMPROVEMENT: Prevent overlapping loader executions.

        The previous procedure allowed a SQL Agent run and a manual run to execute concurrently. That could
        duplicate remote work, increase linked-server load, and create race conditions around NOT EXISTS.
    ***********************************************************************************************************/
    EXEC @ApplicationLockResult = sys.sp_getapplock
        @Resource = 'HeatMap3GTLast48HoursLoader_Canary_RobertDees',
        @LockMode = 'Exclusive',
        @LockOwner = 'Session',
        @LockTimeout = 0;

    IF @ApplicationLockResult < 0
    BEGIN
        SELECT
            'Skipped' AS RunStatus,
            'Another Canary heat-map loader execution is already running.' AS RunMessage;
        RETURN;
    END;

    BEGIN TRY
        SET @ErrorLocation = 'Validation';

        IF @HoursBack IS NULL OR @HoursBack < 1 OR @HoursBack > 180
        BEGIN
            THROW 50001, '@HoursBack must be between 1 and 180.', 1;
        END;

        /* The current partial hour is excluded. Each period ends at or before @LastHour. */
        SET @LastHour = DATEADD(HOUR, DATEDIFF(HOUR, 0, GETDATE()), 0);
        SET @FirstHour = DATEADD(HOUR, -@HoursBack, @LastHour);

        /********************************************************************************************************
            REMOVED LEGACY TIME-ARRAY LOGIC

            Reason removed:
                INFORMATION_SCHEMA.TABLES is not a reliable sequence generator. The number of available rows
                depends on the number of tables in the database. A temporary number table is deterministic.

        DECLARE @TimeArray AS TABLE
        (
            DateTimeFrom SMALLDATETIME,
            DateTimeTo SMALLDATETIME
        );

        INSERT INTO @TimeArray
        SELECT
            DATEADD(hh, -t.seq_nmb, @LastHour),
            DATEADD(hh, -t.seq_nmb + 1, @LastHour)
        FROM
        (
            SELECT ROW_NUMBER() OVER (ORDER BY table_schema) AS seq_nmb
            FROM INFORMATION_SCHEMA.TABLES
        ) AS t
        WHERE t.seq_nmb <= 48;
        ********************************************************************************************************/

        /********************************************************************************************************
            IMPROVEMENT: Temporary tables support statistics and indexes, improving work-queue joins.
        ********************************************************************************************************/
        CREATE TABLE #TimeArray
        (
            DateTimeFrom SMALLDATETIME NOT NULL,
            DateTimeTo SMALLDATETIME NOT NULL,
            CONSTRAINT PK_TimeArray PRIMARY KEY CLUSTERED (DateTimeFrom)
        );

        CREATE TABLE #Numbers
        (
            NumberValue INT NOT NULL
                CONSTRAINT PK_Numbers PRIMARY KEY CLUSTERED
        );

        ;WITH NumberSource AS
        (
            SELECT TOP (@HoursBack)
                ROW_NUMBER() OVER (ORDER BY object_id, column_id) AS NumberValue
            FROM sys.all_columns
        )
        INSERT INTO #Numbers (NumberValue)
        SELECT NumberValue
        FROM NumberSource;

        INSERT INTO #TimeArray (DateTimeFrom, DateTimeTo)
        SELECT
            DATEADD(HOUR, -NumberValue, @LastHour),
            DATEADD(HOUR, -NumberValue + 1, @LastHour)
        FROM #Numbers;

        /********************************************************************************************************
            RETENTION: Preserve the existing 180-hour history requirement.

            REMOVED LEGACY EXPRESSION:
                WHERE DateTimeFrom < (SELECT DATEADD(hh, -180, GETDATE()))

            Improvement:
                Uses the rounded @LastHour boundary and removes the unnecessary scalar SELECT.
        ********************************************************************************************************/
        SET @ErrorLocation = 'Retention';

        DELETE FROM dbo.heatMap3GTLast48Hours_Canary
        WHERE DateTimeFrom < DATEADD(HOUR, -180, @LastHour);

        SET @RowsDeleted = @@ROWCOUNT;

        /********************************************************************************************************
            IMPROVEMENT: Optional controlled rebuild.

            @ReloadExisting = 0 loads only missing configured tag-hours.
            @ReloadExisting = 1 deletes and reloads the requested window for active configured tags.
        ********************************************************************************************************/
        IF @ReloadExisting = 1
        BEGIN
            SET @ErrorLocation = 'ReloadDelete';

            DELETE target
            FROM dbo.heatMap3GTLast48Hours_Canary AS target
            INNER JOIN dbo.maint_3GTHeatMapTags_Canary AS configured
                ON configured.LineID = target.LineID
               AND configured.TagName = target.TagName
            INNER JOIN dbo.maint_Line AS productionLine
                ON productionLine.LineID = configured.LineID
            WHERE productionLine.ProductionInd = 'Y'
              AND target.DateTimeFrom >= @FirstHour
              AND target.DateTimeFrom < @LastHour;

            SET @RowsDeleted = @RowsDeleted + @@ROWCOUNT;
        END;

        /********************************************************************************************************
            REMOVED LEGACY CURSOR SOURCE

            Reason removed:
                The old cursor repeatedly combined a table variable, configuration table, line table, and target
                table. The new code materializes missing work once in an indexed queue.

        DECLARE db_3GT_48Hr_Loader_Cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT ht.LineID, ta.DateTimeFrom, ta.DateTimeTo, ht.TagName
            FROM @TimeArray AS ta
            CROSS JOIN dbo.maint_3GTHeatMapTags_Canary AS ht
            INNER JOIN dbo.maint_Line AS ml
                ON ml.LineID = ht.LineID
            WHERE ml.ProductionInd = 'Y'
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.heatMap3GTLast48Hours_Canary AS existing
                  WHERE existing.LineID = ht.LineID
                    AND existing.TagName = ht.TagName
                    AND existing.DateTimeFrom = ta.DateTimeFrom
              );
        ********************************************************************************************************/

        SET @ErrorLocation = 'WorkQueue';

        CREATE TABLE #WorkQueue
        (
            WorkID INT IDENTITY(1,1) NOT NULL,
            LineID TINYINT NOT NULL,
            DateTimeFrom SMALLDATETIME NOT NULL,
            DateTimeTo SMALLDATETIME NOT NULL,
            TagName VARCHAR(500) NOT NULL,
            CONSTRAINT PK_WorkQueue PRIMARY KEY CLUSTERED (WorkID),
            CONSTRAINT UQ_WorkQueue UNIQUE NONCLUSTERED (LineID, TagName, DateTimeFrom)
        );

        INSERT INTO #WorkQueue
        (
            LineID,
            DateTimeFrom,
            DateTimeTo,
            TagName
        )
        SELECT
            configured.LineID,
            timePeriod.DateTimeFrom,
            timePeriod.DateTimeTo,
            configured.TagName
        FROM dbo.maint_3GTHeatMapTags_Canary AS configured
        INNER JOIN dbo.maint_Line AS productionLine
            ON productionLine.LineID = configured.LineID
        CROSS JOIN #TimeArray AS timePeriod
        WHERE productionLine.ProductionInd = 'Y'
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.heatMap3GTLast48Hours_Canary AS existing
              WHERE existing.LineID = configured.LineID
                AND existing.TagName = configured.TagName
                AND existing.DateTimeFrom = timePeriod.DateTimeFrom
          );

        SET @WorkItems = @@ROWCOUNT;

        /********************************************************************************************************
            IMPROVEMENT: Keep the FAST_FORWARD cursor only around the unavoidable remote stored-procedure call.

            dbo.TagValue_Canary currently performs one Canary query per tag-hour. Processing newest periods first
            improves dashboard continuity if a remote dependency becomes temporarily unavailable mid-run.
        ********************************************************************************************************/
        IF @WorkItems > 0
        BEGIN
            SET @ErrorLocation = 'CanaryLoad';

            DECLARE CanaryHeatMapCursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT
                    LineID,
                    DateTimeFrom,
                    DateTimeTo,
                    TagName
                FROM #WorkQueue
                ORDER BY DateTimeFrom DESC, LineID, TagName;

            OPEN CanaryHeatMapCursor;

            FETCH NEXT FROM CanaryHeatMapCursor
            INTO @LineID, @DateTimeFrom, @DateTimeTo, @TagName;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @TagValue = NULL;

                EXEC @TagValue = dbo.TagValue_Canary
                    @StartDateTime = @DateTimeFrom,
                    @EndDateTime = @DateTimeTo,
                    @TagName = @TagName;

                /* Recheck protects against unexpected concurrent inserts from another process. */
                INSERT INTO dbo.heatMap3GTLast48Hours_Canary
                (
                    LineID,
                    DateTimeFrom,
                    DateTimeTo,
                    TagName,
                    TagValue
                )
                SELECT
                    @LineID,
                    @DateTimeFrom,
                    @DateTimeTo,
                    @TagName,
                    ISNULL(@TagValue, 0)
                WHERE NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.heatMap3GTLast48Hours_Canary AS existing
                    WHERE existing.LineID = @LineID
                      AND existing.TagName = @TagName
                      AND existing.DateTimeFrom = @DateTimeFrom
                );

                SET @RowsInserted = @RowsInserted + @@ROWCOUNT;

                FETCH NEXT FROM CanaryHeatMapCursor
                INTO @LineID, @DateTimeFrom, @DateTimeTo, @TagName;
            END;

            CLOSE CanaryHeatMapCursor;
            DEALLOCATE CanaryHeatMapCursor;
        END;

        /********************************************************************************************************
            REMOVED LEGACY LOT-RANGE TABLE VARIABLES AND IDENTITY SELF-JOIN

            Reason removed:
                LEAD returns the next lot start directly. Temporary tables provide indexes and statistics.

        DECLARE @LotStartEnd AS TABLE
        (
            ID INT IDENTITY(1,1),
            LineName VARCHAR(50),
            LotNum VARCHAR(10),
            LotStartDate SMALLDATETIME,
            LotEndDate SMALLDATETIME,
            ProductID VARCHAR(10),
            Brand VARCHAR(10),
            SpherePower VARCHAR(25)
        );

        DECLARE @LotStartEndBrand AS TABLE
        (
            ID INT,
            LineID TINYINT,
            LotNum VARCHAR(10),
            LotStartDate SMALLDATETIME,
            LotEndDate SMALLDATETIME,
            Brand VARCHAR(10),
            SpherePower VARCHAR(25)
        );

        INSERT INTO @LotStartEndBrand
        SELECT t1.ID, ml.LineID, t1.LotNum, t1.LotStartDate,
               ISNULL(t2.LotStartDate, GETDATE()), t1.Brand, t1.SpherePower
        FROM @LotStartEnd AS t1
        INNER JOIN dbo.maint_Line AS ml
            ON t1.LineName = SUBSTRING(UPPER(ml.LineName), 5, 10)
        LEFT JOIN @LotStartEnd AS t2
            ON t1.ID = t2.ID - 1
           AND t1.LineName = t2.LineName
        WHERE ml.ProductionInd = 'Y';
        ********************************************************************************************************/

        /********************************************************************************************************
            IMPROVEMENT: Remote Oracle work remains outside the local transaction.
        ********************************************************************************************************/
        SET @ErrorLocation = 'LotQuery';

        CREATE TABLE #LotStart
        (
            LineName VARCHAR(50) NOT NULL,
            LotNum VARCHAR(10) NULL,
            LotStartDate SMALLDATETIME NOT NULL,
            ProductID VARCHAR(10) NULL,
            Brand VARCHAR(10) NULL,
            SpherePower VARCHAR(25) NULL
        );

        INSERT INTO #LotStart
        (
            LineName,
            LotNum,
            LotStartDate,
            ProductID,
            Brand,
            SpherePower
        )
        SELECT
            LineName,
            LotNum,
            LotStartDate,
            ProductID,
            Brand,
            SpherePower
        FROM OPENQUERY
        (
            MNFDB_P3GT,
            '
                SELECT
                    la.LSMACHINE_NO AS LineName,
                    la.LOT_NO AS LotNum,
                    la.LS_DATETIME AS LotStartDate,
                    la.PRODUCT_ID AS ProductID,
                    spidm.BRAND AS Brand,
                    CASE
                        WHEN spidm.cylinder IS NOT NULL THEN
                            TO_CHAR
                            (
                                spidm.Base_Curve || '' '' ||
                                spidm.sphere_power || '' '' ||
                                spidm.cylinder || ''/'' ||
                                spidm.axis
                            )
                        WHEN spidm.add_power IS NOT NULL THEN
                            TO_CHAR
                            (
                                spidm.Base_Curve || '' '' ||
                                spidm.sphere_power || '' / '' ||
                                spidm.add_power
                            )
                        ELSE
                            spidm.Base_Curve || '' '' || spidm.sphere_power
                    END AS SpherePower
                FROM OWNER_3GT.LOT_DATA la
                INNER JOIN OWNER_3GT.S_PROD_ID_MASTER spidm
                    ON la.PRODUCT_ID = spidm.PRODUCT_ID
                WHERE la.LS_DATETIME > SYSDATE - 6
                  AND la.LSMACHINE_NO NOT LIKE ''LINE%''
                  AND la.LOT_STATUS = ''IN-PROCESS''
            '
        );

        CREATE CLUSTERED INDEX IX_LotStart
            ON #LotStart (LineName, LotStartDate);

        CREATE TABLE #LotRange
        (
            LineID TINYINT NOT NULL,
            LotNum VARCHAR(10) NULL,
            LotStartDate SMALLDATETIME NOT NULL,
            LotEndDate SMALLDATETIME NOT NULL,
            Brand VARCHAR(10) NULL,
            SpherePower VARCHAR(25) NULL
        );

        ;WITH LotSequence AS
        (
            SELECT
                lot.LineName,
                lot.LotNum,
                lot.LotStartDate,
                LEAD(lot.LotStartDate) OVER
                (
                    PARTITION BY lot.LineName
                    ORDER BY lot.LotStartDate
                ) AS NextLotStartDate,
                lot.Brand,
                lot.SpherePower
            FROM #LotStart AS lot
        )
        INSERT INTO #LotRange
        (
            LineID,
            LotNum,
            LotStartDate,
            LotEndDate,
            Brand,
            SpherePower
        )
        SELECT
            productionLine.LineID,
            lot.LotNum,
            lot.LotStartDate,
            ISNULL(lot.NextLotStartDate, GETDATE()),
            lot.Brand,
            lot.SpherePower
        FROM LotSequence AS lot
        INNER JOIN dbo.maint_Line AS productionLine
            ON lot.LineName = SUBSTRING(UPPER(productionLine.LineName), 5, 10)
        WHERE productionLine.ProductionInd = 'Y';

        CREATE CLUSTERED INDEX IX_LotRange
            ON #LotRange (LineID, LotStartDate, LotEndDate);

        /********************************************************************************************************
            REMOVED LEGACY BRAND UPDATE

            Reason removed:
                The prior update could touch every matching row even when Brand and SpherePower already matched.
                It also placed remote Oracle work inside a transaction.

        BEGIN TRANSACTION;

        UPDATE dbo.heatMap3GTLast48Hours_Canary
        SET Brand = v.Brnd,
            SpherePower = v.SphPwr
        FROM
        (
            SELECT ta.DateTimeFrom AS Dtf,
                   ta.DateTimeTo,
                   lseb.LineID AS LnID,
                   lseb.Brand AS Brnd,
                   lseb.SpherePower AS SphPwr
            FROM @TimeArray AS ta
            LEFT JOIN @LotStartEndBrand AS lseb
                ON ta.DateTimeFrom >= lseb.LotStartDate
               AND ta.DateTimeFrom < lseb.LotEndDate
        ) AS v
        WHERE LineID = v.LnID
          AND DateTimeFrom = v.Dtf;

        COMMIT TRANSACTION;
        ********************************************************************************************************/

        /********************************************************************************************************
            IMPROVEMENT: Short local transaction and changed-value predicate reduce locking and log activity.
        ********************************************************************************************************/
        SET @ErrorLocation = 'BrandUpdate';

        BEGIN TRANSACTION;

        UPDATE target
        SET
            target.Brand = lot.Brand,
            target.SpherePower = lot.SpherePower
        FROM dbo.heatMap3GTLast48Hours_Canary AS target
        INNER JOIN #LotRange AS lot
            ON lot.LineID = target.LineID
           AND target.DateTimeFrom >= lot.LotStartDate
           AND target.DateTimeFrom < lot.LotEndDate
        WHERE target.DateTimeFrom >= @FirstHour
          AND target.DateTimeFrom < @LastHour
          AND
          (
              ISNULL(target.Brand, '') <> ISNULL(lot.Brand, '')
              OR ISNULL(target.SpherePower, '') <> ISNULL(lot.SpherePower, '')
          );

        SET @BrandRowsUpdated = @@ROWCOUNT;

        COMMIT TRANSACTION;

        EXEC sys.sp_releaseapplock
            @Resource = 'HeatMap3GTLast48HoursLoader_Canary_RobertDees',
            @LockOwner = 'Session';

        /********************************************************************************************************
            IMPROVEMENT: Compact run summary for SQL Agent history and troubleshooting.
        ********************************************************************************************************/
        SELECT
            'Completed' AS RunStatus,
            @FirstHour AS WindowStart,
            @LastHour AS WindowEnd,
            @HoursBack AS HoursRequested,
            @ReloadExisting AS ReloadExisting,
            @WorkItems AS WorkItemsFound,
            @RowsInserted AS RowsInserted,
            @RowsDeleted AS RowsDeleted,
            @BrandRowsUpdated AS BrandRowsUpdated,
            COUNT(*) AS RowsInCanaryHeatMap,
            MIN(DateTimeFrom) AS OldestStoredHour,
            MAX(DateTimeFrom) AS NewestStoredHour
        FROM dbo.heatMap3GTLast48Hours_Canary;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'CanaryHeatMapCursor') >= 0
        BEGIN
            CLOSE CanaryHeatMapCursor;
        END;

        IF CURSOR_STATUS('local', 'CanaryHeatMapCursor') > -3
        BEGIN
            DEALLOCATE CanaryHeatMapCursor;
        END;

        IF @@TRANCOUNT > 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = 'HeatMap3GTLast48HoursLoader_Canary_RobertDees',
            @LockOwner = 'Session';

        INSERT INTO dbo.maint_Error
        (
            date,
            description,
            location
        )
        VALUES
        (
            GETDATE(),
            LEFT
            (
                'Error=' + CONVERT(VARCHAR(20), ERROR_NUMBER())
                + '; SQLLine=' + CONVERT(VARCHAR(20), ERROR_LINE())
                + '; Message=' + ERROR_MESSAGE()
                + '; LineID=' + ISNULL(CONVERT(VARCHAR(10), @LineID), '')
                + '; Tag=' + ISNULL(@TagName, '')
                + '; Hour=' + ISNULL(CONVERT(VARCHAR(19), @DateTimeFrom, 120), ''),
                1000
            ),
            LEFT
            (
                @ProcedureName + '; Location=' + ISNULL(@ErrorLocation, 'Unknown'),
                250
            )
        );

        THROW;
    END CATCH;
END;
GO

/***************************************************************************************************************
OPTIONAL ONE-TIME SUPPORTING INDEXES

Review existing indexes before execution. These statements are intentionally commented out so deploying the
procedure does not change table indexes automatically.

The unique index accelerates NOT EXISTS checks and enforces one row per LineID, TagName, and DateTimeFrom.
Run the duplicate check first. If it returns zero rows, the unique index can be created.
***************************************************************************************************************/

/*
-- Duplicate check
SELECT
    LineID,
    TagName,
    DateTimeFrom,
    COUNT(*) AS DuplicateRows
FROM dbo.heatMap3GTLast48Hours_Canary
GROUP BY
    LineID,
    TagName,
    DateTimeFrom
HAVING COUNT(*) > 1;
GO

-- Recommended uniqueness and lookup index
CREATE UNIQUE NONCLUSTERED INDEX UX_heatMap3GTLast48Hours_Canary_Line_Tag_Hour
ON dbo.heatMap3GTLast48Hours_Canary
(
    LineID,
    TagName,
    DateTimeFrom
)
INCLUDE
(
    DateTimeTo,
    TagValue,
    Brand,
    SpherePower
);
GO

-- Recommended retention cleanup index
CREATE NONCLUSTERED INDEX IX_heatMap3GTLast48Hours_Canary_DateTimeFrom
ON dbo.heatMap3GTLast48Hours_Canary
(
    DateTimeFrom
);
GO
*/
