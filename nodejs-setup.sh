#!/bin/bash

# Install Node.js and npm
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install PM2 process manager
sudo npm install -g pm2

# Create project directory
mkdir /home/nodeapp && cd /home/nodeapp

# Initialize Node.js project
npm init -y

# Install required packages
npm install express mssql dotenv

# Create environment file with SQL connection details
cat > .env <<EOL
SQL_SERVER=<your-sql-server.database.windows.net>
SQL_DATABASE=<your-database-name>
SQL_USER=<your-sql-username>
SQL_PASSWORD=<your-sql-password>
EOL

# Create basic Express app
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

# Start application with PM2 and set up startup script
pm2 start app.js
pm2 startup
pm2 save

# Allow HTTP traffic
sudo ufw allow 80
sudo ufw allow 3000
sudo ufw enable
