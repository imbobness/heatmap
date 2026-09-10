USE [ManufacturingDB]
GO

/****** Object:  StoredProcedure [dbo].[HeatMap3GTLast48HoursLoader_Canary_RobertDees]    Script Date: 9/10/2026 6:52:45 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



/***************************************************************************************************************
Author: Valeriy Yakovelv
Date  : 02/06/2015
Description: This SP loads  records in the tables heatMap3GTLast48Hours_Canary and heatMap3GTCellValues
             for KPI page "3GT Heat Map" 
Modification: 
              Brian Foroud 08/22/2016  
	          Request from Kevin Lively 3GT HeatMap for an on demand report for 14 shifts.   
			  
SELECT *
FROM heatMap3GTLast48Hours_Canary
ORDER BY DateTimeTo DESC

	          
EXEC HeatMap3GTLast48HoursLoader
***************************************************************************************************************/
CREATE   PROCEDURE [dbo].[HeatMap3GTLast48HoursLoader_Canary_RobertDees]
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;

	DECLARE @LineID AS TINYINT
	DECLARE @LastHour SMALLDATETIME
	DECLARE @error_location AS VARCHAR(10)

	SET @LastHour = DATEADD(hh, DATEDIFF(hour, 0, GETDATE()), 0)

	DECLARE @TimeArray AS TABLE (DateTimeFrom SMALLDATETIME,DateTimeTo SMALLDATETIME) 
/***************************************************************************************************************
    We use this table as a source of last 48 hours records. It lets us delete old record
    (49th hour) and add new (last hour data)
***************************************************************************************************************/
	INSERT INTO @TimeArray
	SELECT DATEADD(hh,-t.seq_nmb,@LastHour) DateTimeFrom,DATEADD(hh,-t.seq_nmb+1,@LastHour) DateTimeTo
	FROM
	   (
		SELECT row_number() over(order by table_schema) AS seq_nmb FROM INFORMATION_SCHEMA.TABLES
	   ) t
	 WHERE t.seq_nmb <= 48 

BEGIN TRY

/***************************************************************************************************************
	Prepare and load records into heatMap3GTLast48Hours_Canary
***************************************************************************************************************/
	-- Brian Foroud 08/22/2016. Request from Kevin Lively 3GT HeatMap new on demand report for
	-- 14 shifts, or  -180 hours.
	--DELETE FROM heatMap3GTLast48Hours_Canary--deleting 49th hour records
	--WHERE DateTimeFrom NOT IN (SELECT DateTimeFrom FROM @TimeArray)
	
	DELETE FROM heatMap3GTLast48Hours_Canary--deleting 49th hour records
	WHERE DateTimeFrom < (SELECT DATEADD (hh, -180, GetDate() ) )
	
    DECLARE @DateTimeFrom AS SMALLDATETIME
    DECLARE @DateTimeTo AS SMALLDATETIME
    DECLARE @TagName AS VARCHAR(500)
    DECLARE @TagValue AS INT
/***************************************************************************************************************
    Populate table heatMap3GTLast48Hours_Canary with new records for the latest hour
***************************************************************************************************************/
    SET @error_location='1'
    
        DECLARE db_3GT_48Hr_Loader_Cursor
CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        ht.LineID,
        ta.DateTimeFrom,
        ta.DateTimeTo,
        ht.TagName
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

OPEN db_3GT_48Hr_Loader_Cursor;

FETCH NEXT FROM db_3GT_48Hr_Loader_Cursor
INTO
    @LineID,
    @DateTimeFrom,
    @DateTimeTo,
    @TagName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @TagValue = NULL;

    EXEC @TagValue = dbo.TagValue_Canary
        @DateTimeFrom,
        @DateTimeTo,
        @TagName;

    INSERT INTO dbo.heatMap3GTLast48Hours_Canary
    (
        LineID,
        DateTimeFrom,
        DateTimeTo,
        TagName,
        TagValue
    )
    VALUES
    (
        @LineID,
        @DateTimeFrom,
        @DateTimeTo,
        @TagName,
        ISNULL(@TagValue, 0)
    );

    FETCH NEXT FROM db_3GT_48Hr_Loader_Cursor
    INTO
        @LineID,
        @DateTimeFrom,
        @DateTimeTo,
        @TagName;
END;

CLOSE db_3GT_48Hr_Loader_Cursor;
DEALLOCATE db_3GT_48Hr_Loader_Cursor;
BEGIN TRANSACTION

/***************************************************************************************************************
    Determine lot start-end (next lot start=previous lot end)
***************************************************************************************************************/
    SET @error_location='2'
	DECLARE @LotStartEnd AS TABLE (ID INT IDENTITY(1,1), LineName VARCHAR(50), LotNum VARCHAR(10), 
								   LotStartDate SMALLDATETIME, LotEndDate SMALLDATETIME,
    ProductID VARCHAR(10),Brand VARCHAR(10),SpherePower VARCHAR(25))

	INSERT INTO @LotStartEnd (LineName,LotNum,LotStartDate,ProductID,Brand,SpherePower)
	SELECT LineName, LotNum, LotStartDate, ProductID, Brand, SpherePower
	FROM OPENQUERY(MNFDB_P3GT, 
						'SELECT  la.LSMACHINE_NO AS LineName,
									la.LOT_NO AS LotNum,
									la.LS_DATETIME AS LotStartDate,
									la.PRODUCT_ID AS ProductID,
									spidm.BRAND AS Brand,
									CASE WHEN spidm.cylinder IS NOT NULL THEN TO_CHAR(spidm.Base_Curve||'' ''||spidm.sphere_power||'' ''||spidm.cylinder||''/''||spidm.axis) 
										WHEN spidm.add_power IS NOT NULL THEN TO_CHAR(spidm.Base_Curve||'' ''||spidm.sphere_power||'' / ''||spidm.add_power) 
									ELSE spidm.Base_Curve||'' ''||spidm.sphere_power
									END AS spherepower 
						 FROM OWNER_3GT.LOT_DATA la
						 INNER JOIN OWNER_3GT.S_PROD_ID_MASTER spidm ON la.PRODUCT_ID=spidm.PRODUCT_ID 
						 WHERE la.LS_DATETIME > SYSDATE-6 
						 AND la.LSMACHINE_NO NOT LIKE ''LINE%'' 
						 AND la.LOT_STATUS=''IN-PROCESS''
					   ')
	ORDER BY LineName, LotStartDate
/***************************************************************************************************************
	--we find lots within last 6 days to have higher probability to grab lot start-end time
***************************************************************************************************************/

	DECLARE @LotStartEndBrand AS TABLE 
	      (ID INT,LineID TINYINT,LotNum VARCHAR(10),LotStartDate SMALLDATETIME,
	       LotEndDate SMALLDATETIME,Brand VARCHAR(10),SpherePower VARCHAR(25))
    SET @error_location='3'
	INSERT INTO @LotStartEndBrand
	SELECT t1.ID, ml.LineID, t1.LotNum, t1.LotStartDate, ISNULL(t2.LotStartDate,GETDATE()) AS LotEndDate,
		   t1.Brand, t1.SpherePower
	FROM @LotStartEnd t1
	INNER JOIN maint_Line ml ON t1.LineName=SUBSTRING(UPPER(ml.LineName),5,10)
	LEFT JOIN @LotStartEnd t2 ON t1.ID=t2.ID-1 AND t1.LineName=t2.LineName
	WHERE ml.ProductionInd='Y'
/***************************************************************************************************************
    Update brand and sphere power in heatMap3GTLast48Hours_Canary 
***************************************************************************************************************/
    SET @error_location='4'
	UPDATE heatMap3GTLast48Hours_Canary
       SET Brand=v.Brnd,
           SpherePower=v.SphPwr
    FROM
     (
       SELECT ta.DateTimeFrom Dtf, ta.DateTimeTo, lseb.LineID LnID, lseb.Brand Brnd, lseb.SpherePower SphPwr
       FROM @TimeArray ta
       LEFT JOIN @LotStartEndBrand lseb ON ta.DateTimeFrom >=lseb.LotStartDate AND ta.DateTimeFrom < lseb.LotEndDate
      ) v
      WHERE LineID=v.LnID 
	  AND DateTimeFrom=v.Dtf   
	  
    SET @error_location='5'  

COMMIT TRANSACTION
END TRY
BEGIN CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION
  DECLARE @ErrorMessage AS VARCHAR(1000)
  SET @ErrorMessage=ERROR_MESSAGE()
  INSERT INTO maint_Error(date, description, location)
  SELECT GETDATE(), @ErrorMessage, 'Procedure "HeatMap3GTLast48HoursLoader"; Location-'+ @error_location
END CATCH


SELECT
    COUNT(*) AS RowsInCanaryHeatMap,
    MIN(DateTimeFrom) AS OldestHour,
    MAX(DateTimeFrom) AS NewestHour
FROM dbo.heatMap3GTLast48Hours_Canary;
END 
GO


