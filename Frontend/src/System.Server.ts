import express from "express";
import path from "path";
import fs from "fs/promises";
import { createServer as createViteServer } from "vite";

async function startServer() {
  const app = express();
  const PORT = 3000;

  // API routes FIRST
  app.get("/api/applets", async (req, res) => {
    try {
      const isProd = process.env.NODE_ENV === "production";
      const appletsDir = isProd 
        ? path.join(process.cwd(), 'dist', 'applets')
        : path.join(process.cwd(), 'public', 'applets');
      
      let files: string[] = [];
      try {
        files = await fs.readdir(appletsDir);
      } catch (e) {
        // Directory might not exist
      }
      
      const htmlFiles = files.filter(f => f.endsWith('.html'));
      res.json({ applets: htmlFiles });
    } catch (error) {
      console.error(error);
      res.status(500).json({ error: "Failed to list applets" });
    }
  });

  app.get("/api/scripts", async (req, res) => {
    try {
      const isProd = process.env.NODE_ENV === "production";
      const scriptsDir = isProd 
        ? path.join(process.cwd(), 'dist', 'scripts')
        : path.join(process.cwd(), 'public', 'scripts');
      
      let files: string[] = [];
      try {
        files = await fs.readdir(scriptsDir);
      } catch (e) {
        // Directory might not exist
      }
      
      const scriptFiles = files.filter(f => f.endsWith('.ps1') || f.endsWith('.sh') || f.endsWith('.bat') || f.endsWith('.cmd') || f.endsWith('.js') || f.endsWith('.py') || f.endsWith('.txt'));
      res.json({ scripts: scriptFiles });
    } catch (error) {
      console.error(error);
      res.status(500).json({ error: "Failed to list scripts" });
    }
  });

  // Vite middleware for development
  if (process.env.NODE_ENV !== "production") {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "spa",
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), 'dist');
    app.use(express.static(distPath));
    app.get('*', (req, res) => {
      res.sendFile(path.join(distPath, 'index.html'));
    });
  }

  app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server running on http://localhost:${PORT}`);
  });
}

startServer();
