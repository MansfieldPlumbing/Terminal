import fs from 'fs';

let app = fs.readFileSync('src/App.tsx', 'utf-8');
app = app.replace(/> Notepad/g, '> Editor');
app = app.replace(/<FileText size=\{18\} className="text-blue-400" \/> Notepad/g, '<FileText size={18} className="text-blue-400" /> Editor');
app = app.replace(/<FolderTree size=\{18\} className="text-yellow-400" \/> File Explorer/g, '<FolderTree size={18} className="text-yellow-400" /> Files');
fs.writeFileSync('src/App.tsx', app);

let cmd = fs.readFileSync('src/components/FloatingCommandPalette.tsx', 'utf-8');
cmd = cmd.replace(/Open Notepad/g, 'Open Editor');
cmd = cmd.replace(/File Explorer/g, 'Files');
fs.writeFileSync('src/components/FloatingCommandPalette.tsx', cmd);
