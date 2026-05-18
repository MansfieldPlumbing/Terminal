import React from 'react';
import { Tab } from '../System.Store';

export default function TerminalFiles({ tab }: { tab: Tab }) {
  return (
    <div style={{ position: 'absolute', inset: 0, backgroundColor: '#111', color: '#ccc', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'sans-serif', fontSize: '14px' }}>
      File Explorer — coming soon
    </div>
  );
}
