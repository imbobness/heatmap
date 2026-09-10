import pandas as pd
import pyodbc
import win32com.client as win32

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

sql = """
SELECT
    Plant_Code,
    NC_Num,
    LotNum,
    NC_Category,
    NC_EventType,
    NC_Event_Sub_Type,
    Entry_Date,
    Closure_Date,
    CASE
        WHEN Closure_Date IS NULL THEN 'OPEN'
        ELSE 'CLOSED'
    END AS Status
FROM dbo.Vibes_Lot_NC_Event_View
WHERE Plant_Code = 'US11'
  AND CAST(Entry_Date AS DATE) = CAST(GETDATE() AS DATE)
ORDER BY
    Entry_Date DESC,
    NC_Num,
    LotNum;
"""

conn = pyodbc.connect(conn_str)
df = pd.read_sql(sql, conn)
conn.close()

if df.empty:
    html = "<h3>No US11 Quality Events found today.</h3>"
else:
    html_table = df.to_html(
        index=False,
        border=1,
        justify="left"
    )

    open_qes = df[df["Status"] == "OPEN"]["NC_Num"].nunique()

    html = f"""
    <html>
    <body>

    <h2>US11 Quality Events</h2>

    <p>
    Total Records: <b>{len(df)}</b><br>
    Unique QEs: <b>{df['NC_Num'].nunique()}</b><br>
    Open QEs: <b>{open_qes}</b>
    </p>

    {html_table}

    </body>
    </html>
    """

outlook = win32.Dispatch("Outlook.Application")

mail = outlook.CreateItem(0)

mail.To = "rdees1@its.jnj.com; PTREMBLA@its.jnj.com"

mail.Subject = "US11 Daily Quality Events"

mail.HTMLBody = html

mail.Send()

print(
    f"Sent email with "
    f"{df['NC_Num'].nunique()} QEs and "
    f"{len(df)} affected lots"
)