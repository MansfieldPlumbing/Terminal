import React, { useRef, useEffect, useState } from 'react';
import { useAppStore, Tab } from '../store';
import Editor, { useMonaco } from '@monaco-editor/react';

export default function NativeNotepad({ tab }: { tab: Tab }) {
  const { updateTabContent, updateTabTitle } = useAppStore();
  const editorRef = useRef<any>(null);
  const [wordWrap, setWordWrap] = useState<'on' | 'off'>('off');
  const [minimap, setMinimap] = useState<boolean>(true);

  const getLanguage = (filename: string) => {
    if (tab.language) return tab.language;
    const ext = filename.split('.').pop()?.toLowerCase();
    switch (ext) {
      case 'js':
      case 'jsx': return 'javascript';
      case 'ts':
      case 'tsx': return 'typescript';
      case 'json': return 'json';
      case 'html': return 'html';
      case 'css': return 'css';
      case 'cpp':
      case 'c':
      case 'h':
      case 'hpp': return 'cpp';
      case 'py': return 'python';
      case 'ps1': return 'powershell';
      case 'sh': return 'shell';
      case 'md': return 'markdown';
      case 'xml': return 'xml';
      default: return 'plaintext';
    }
  };
  
  const language = getLanguage(tab.title);

  useEffect(() => {
    const handleAction = async (e: CustomEvent) => {
      if (e.detail.tabId !== tab.id) return;
      const editor = editorRef.current;
      if (!editor) return;

      switch (e.detail.action) {
        case 'open':
          try {
            if (!(window as any).showOpenFilePicker) {
               alert("File System Access API is not supported in this browser.");
               return;
            }
            const [handle] = await (window as any).showOpenFilePicker();
            const file = await handle.getFile();
            const text = await file.text();
            updateTabContent(tab.id, text);
            updateTabTitle(tab.id, file.name);
          } catch(e) {
            // Cancelled
          }
          break;
        case 'save':
          console.log('Save triggered for', tab.title);
          break;
        case 'undo':
          editor.trigger('AppMenu', 'undo', null);
          break;
        case 'redo':
          editor.trigger('AppMenu', 'redo', null);
          break;
        case 'cut':
          editor.trigger('AppMenu', 'editor.action.clipboardCutAction', null);
          break;
        case 'copy':
          editor.trigger('AppMenu', 'editor.action.clipboardCopyAction', null);
          break;
        case 'paste':
          editor.trigger('AppMenu', 'editor.action.clipboardPasteAction', null);
          break;
        case 'select-all':
          editor.setSelection(editor.getModel().getFullModelRange());
          break;
        case 'toggle-word-wrap':
          setWordWrap(w => w === 'on' ? 'off' : 'on');
          break;
        case 'toggle-minimap':
          setMinimap(m => !m);
          break;
      }
      editor.focus();
    };

    window.addEventListener('app-menu-action', handleAction as EventListener);
    return () => window.removeEventListener('app-menu-action', handleAction as EventListener);
  }, [tab.id]);

  function handleEditorWillMount(monaco: any) {
    monaco.editor.defineTheme('vibrant-dark', {
      base: 'vs-dark',
      inherit: true,
      rules: [
        { token: 'comment', foreground: '4ade80', fontStyle: 'italic' }, // Green 400
        { token: 'keyword', foreground: 'f472b6', fontStyle: 'bold' }, // Pink 400
        { token: 'string', foreground: 'facc15' }, // Yellow 400
        { token: 'number', foreground: '818cf8' }, // Indigo 400
        { token: 'type', foreground: '38bdf8' }, // Sky 400
        { token: 'class', foreground: '2dd4bf', fontStyle: 'bold' }, // Teal 400
        { token: 'function', foreground: 'a78bfa' }, // Violet 400
        { token: 'identifier', foreground: 'e2e8f0' },
      ],
      colors: {
        'editor.background': '#1e1e1e',
        'editor.foreground': '#e2e8f0',
        'editorLineNumber.foreground': '#475569',
        'editorLineNumber.activeForeground': '#e2e8f0',
        'editor.selectionBackground': '#334155',
        'editor.inactiveSelectionBackground': '#1e293b',
        'minimap.background': '#ffffff05',
        'minimapSlider.background': '#ffffff15',
        'minimapSlider.hoverBackground': '#ffffff30',
        'minimapSlider.activeBackground': '#ffffff50',
      }
    });
  }

  function handleEditorDidMount(editor: any, monaco: any) {
    editorRef.current = editor;
  }

  function handleEditorChange(value: string | undefined, event: any) {
    updateTabContent(tab.id, value || '');
  }
  
  return (
    <div className={`w-full h-full flex flex-col bg-[#1e1e1e] text-[#D4D4D4] font-mono text-[14px] ${minimap ? "monaco-mica-minimap" : ""}`}>
      <div className="flex-1 relative overflow-hidden">
        <Editor
          width="100%"
          height="100%"
          defaultLanguage={language}
          language={language}
          theme="vibrant-dark"
          value={tab.content ?? ''}
          onChange={handleEditorChange}
          onMount={handleEditorDidMount}
          beforeMount={handleEditorWillMount}
          options={{
            minimap: { enabled: minimap, side: 'right' },
            fontSize: 14,
            wordWrap: wordWrap,
            lineNumbers: 'on',
            scrollBeyondLastLine: false,
            smoothScrolling: true,
            cursorBlinking: 'smooth',
            cursorSmoothCaretAnimation: 'on',
            formatOnPaste: true,
            scrollbar: {
              vertical: 'visible',
              horizontal: 'visible',
              useShadows: false,
              verticalScrollbarSize: 10,
              horizontalScrollbarSize: 10,
            },
          }}
        />
      </div>
      <div className="h-6 bg-[#007ACC] text-white flex items-center justify-between px-3 text-[11px] font-sans font-medium select-none shrink-0 border-t border-[#333]">
        <div className="flex items-center gap-4">
          <span>Ready</span>
        </div>
        <div className="flex items-center gap-4 opacity-90">
          <span className="uppercase">{language}</span>
          <span>UTF-8</span>
        </div>
      </div>
    </div>
  );
}
