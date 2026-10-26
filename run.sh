#!/usr/bin/env bash
# Build the database and start the website.
# Run this from the project folder:   ./run.sh
set -e

DB_NAME=${DB_NAME:-result_system}
MYSQL="mysql -u root"

echo "==> 1/3  creating the database and stored routines"
$MYSQL < 01_schema.sql

echo "==> 2/3  loading demo data"
$MYSQL < 02_seed_data.sql

echo "==> 3/3  creating the app database user"
$MYSQL -e "CREATE USER IF NOT EXISTS 'resultapp'@'%' IDENTIFIED BY 'result@123';
           GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'resultapp'@'%';
           FLUSH PRIVILEGES;"

echo
echo "Database ready.  Starting the website on http://localhost:5000"
echo "Press Ctrl+C to stop."
echo
DB_USER=resultapp DB_PASSWORD='result@123' DB_NAME=$DB_NAME python3 app.py
