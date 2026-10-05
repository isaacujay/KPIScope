import pyodbc
from connection import get_connection_string

def test_connection():
    conn_str = get_connection_string()
    conn = pyodbc.connect(conn_str, timeout=5)
    cursor = conn.cursor()

    cursor.execute("SELECT @@SERVERNAME, DB_NAME();")
    print(cursor.fetchone())

    cursor.execute("""
        SELECT name FROM sys.schemas
        WHERE schema_id < 16384
        ORDER BY name;
    """)
    schemas = [row[0] for row in cursor.fetchall()]
    print("Schemas:", schemas)

    cursor.close()
    conn.close()

if __name__ == "__main__":
    test_connection()