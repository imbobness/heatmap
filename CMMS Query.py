import pandas as pd
import pyodbc
import win32com.client as win32

# =========================
# SQL CONNECTION
# =========================

SERVER = "VISUSJAWSP00082"
DATABASE = "ManufacturingDB"
USERNAME = "ApplicationUser"
PASSWORD = "Vis@32256"

conn_str = (
    "DRIVER={ODBC Driver 18 for SQL Server};"
    f"SERVER={SERVER};"
    f"DATABASE={DATABASE};"
    f"UID={USERNAME};"
    f"PWD={PASSWORD};"
    "TrustServerCertificate=yes;"
)

# =========================
# QUERY
# =========================

sql = r"""
SELECT
    src.CMMSRecordID,
    src.ProductionDate,
    src.TeamID,
    src.LineID,
    src.EntryDate,
    src.ResolutionID,
    src.Downtime,
    src.ResolutionComments,
    CASE
        WHEN sd.CMMSRecordID IS NULL THEN 'NOT LOADED'
        ELSE 'LOADED'
    END AS LoadStatus
FROM
(
    SELECT
        t.SHIFT_RECORD_ID AS CMMSRecordID,
        t.PRODUCTION_DATE AS ProductionDate,
        t.TEAM_ID AS TeamID,
        ml.LineID,
        t.CREATE_DATE AS EntryDate,
        t.RESOLUTION_CODE AS ResolutionID,
        t.DOWN_TIME AS Downtime,
        t.SHIFT_COMMENT AS ResolutionComments
    FROM OPENQUERY
    (
        MNFDB_MPOD_CMMS,
        '
        SELECT
            SHIFT_RECORD_ID,
            PRODUCTION_DATE,
            TEAM_ID,
            AREA_INFO_CODE,
            UNIT_NUM,
            RESOLUTION_CODE,
            DOWN_TIME,
            SHIFT_COMMENT,
            CREATE_DATE
        FROM WEB_CMMS.SHIFT_RECORD
        WHERE PRODUCTION_DATE >= TRUNC(SYSDATE)
          AND PRODUCTION_DATE < TRUNC(SYSDATE) + 1
          AND AREA_INFO_CODE = ''3GT''
          AND TEAM_ID = ''A''
          AND RESOLUTION_CODE <> ''ADT''
        '
    ) AS t
    INNER JOIN dbo.maint_Line AS ml
        ON t.UNIT_NUM = ml.CMMSLineID
       AND ml.ProductionInd = 'Y'
) AS src
LEFT JOIN dbo.shift_Downtime AS sd
    ON src.CMMSRecordID = sd.CMMSRecordID
ORDER BY src.EntryDate DESC;
"""

# =========================
# RUN QUERY
# =========================

conn = pyodbc.connect(conn_str)
df = pd.read_sql(sql, conn)
conn.close()

# =========================
# BUILD HTML EMAIL
# =========================

if df.empty:
    html = """
    <h3>No Team A 3GT CMMS records found today.</h3>
    """
else:
    html_table = df.to_html(
        index=False,
        border=1,
        justify="left"
    )

    html = f"""
    <html>
    <body>
        <h2>Today's 3GT Team A CMMS Records</h2>

        <p>
        Total records found:
        <b>{len(df)}</b>
        </p>

        {html_table}

    </body>
    </html>
    """

# =========================
# SEND EMAIL
# =========================

outlook = win32.Dispatch("Outlook.Application")
mail = outlook.CreateItem(0)

mail.To = "rdees1@its.jnj.com",
	  "PTREMBLA@its.jnj.com"
mail.Subject = "3GT Team A CMMS Records"
mail.HTMLBody = html

mail.Send()

print(f"Sent email with {len(df)} records")