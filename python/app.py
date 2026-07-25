import os
import time

import psycopg2

DB_HOST = os.environ.get("DB_HOST", "postgres.app01.svc.cluster.local")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]

while True:
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            connect_timeout=5,
        )
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.fetchone()
        cur.close()
        conn.close()
        print(f"OK: connected to database at {DB_HOST}:{DB_PORT} and query succeeded")
    except Exception as e:
        print(f"ERROR: failed to connect to database at {DB_HOST}:{DB_PORT}")
        print(f"DETAIL: {e}")

    time.sleep(10)
