#!/bin/bash
set -e # Exit immediately on error

# Receive parameters from ARM template
SQL_SERVER=$1
SQL_DATABASE=$2
SQL_USER=$3
SQL_PASSWORD=$4

# Validate parameters
if [ -z "$SQL_SERVER" ] || [ -z "$SQL_DATABASE" ] || [ -z "$SQL_USER" ] || [ -z "$SQL_PASSWORD" ]; then
  echo "Error: Missing SQL connection parameters!"
  exit 1
fi

# System updates and dependencies
sudo apt-get update -y
sudo apt-get install -y build-essential

# Install Node.js 18.x
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install PM2 globally
sudo npm install -g pm2

# Create project directory
APP_DIR="/home/nodeapp"
sudo mkdir -p $APP_DIR
sudo chown $(whoami):$(whoami) $APP_DIR
cd $APP_DIR

# Initialize Node project
npm init -y

# Install required packages
npm install express mssql dotenv

# Create environment file
cat > .env <<EOL
SQL_SERVER=${SQL_SERVER}
SQL_DATABASE=${SQL_DATABASE}
SQL_USER=${SQL_USER}
SQL_PASSWORD=${SQL_PASSWORD}
EOL

# Secure environment file
chmod 600 .env

# Create application file (same as your original app.js content)
cat > app.js <<EOL
require('dotenv').config();
const express = require('express');
const sql = require('mssql');

const app = express();
app.use(express.json());

const config = {
  user: process.env.SQL_USER,
  password: process.env.SQL_PASSWORD,
  server: process.env.SQL_SERVER,
  database: process.env.SQL_DATABASE,
  options: {
    encrypt: true,
    trustServerCertificate: false
  }
};

// Create table if not exists
async function initializeDatabase() {
  try {
    const pool = await sql.connect(config);
    await pool.request().query(\`
      IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='Items' AND xtype='U')
      CREATE TABLE Items (
        ID INT PRIMARY KEY IDENTITY,
        Name NVARCHAR(50) NOT NULL,
        CreatedDate DATETIME DEFAULT GETDATE()
      )
    \`);
    console.log('Database initialized');
  } catch (err) {
    console.error('Database initialization error:', err);
  }
}

// Simple API to save data
app.post('/items', async (req, res) => {
  try {
    const pool = await sql.connect(config);
    const result = await pool.request()
      .input('name', sql.NVarChar(50), req.body.name)
      .query('INSERT INTO Items (Name) OUTPUT INSERTED.* VALUES (@name)');
    
    res.json(result.recordset[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Health check endpoint
app.get('/', (req, res) => {
  res.send('Node.js SQL API is running');
});

initializeDatabase().then(() => {
  const port = process.env.PORT || 3000;
  app.listen(port, () => {
    console.log(\`Server running on port \${port}\`);
  });
});
EOL

# Configure firewall
sudo ufw allow 80
sudo ufw allow 3000
sudo ufw --force enable

# Start application with PM2
pm2 start app.js
pm2 startup
pm2 save

# Verify setup
echo "Installation complete!"
echo "Check application status with: pm2 list"
