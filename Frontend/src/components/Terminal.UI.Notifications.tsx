import React from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { useAppStore } from '../System.Store';
import { CheckCircle, Info, AlertTriangle, XCircle, X } from 'lucide-react';

export default function Notifications() {
  const { notifications, removeNotification } = useAppStore();

  const getIcon = (type: string) => {
    switch (type) {
      case 'success': return <CheckCircle className="w-4 h-4 text-emerald-400" />;
      case 'warn': return <AlertTriangle className="w-4 h-4 text-amber-400" />;
      case 'error': return <XCircle className="w-4 h-4 text-red-400" />;
      default: return <Info className="w-4 h-4 text-blue-400" />;
    }
  };

  return (
    <div className="fixed top-4 right-4 z-[200] flex flex-col gap-2 max-w-sm w-full pointer-events-none">
      <AnimatePresence>
        {notifications.map((notification) => (
          <motion.div
            key={notification.id}
            initial={{ opacity: 0, x: 20, scale: 0.95 }}
            animate={{ opacity: 1, x: 0, scale: 1 }}
            exit={{ opacity: 0, x: 20, scale: 0.95 }}
            className="mica-panel mica-border shadow-2xl rounded-xl p-3 flex items-start gap-3 pointer-events-auto"
          >
            <div className="shrink-0 mt-0.5">{getIcon(notification.type)}</div>
            <div className="flex-1 text-sm text-shadow-mica font-medium leading-tight">
              {notification.message}
            </div>
            <button
              onClick={() => removeNotification(notification.id)}
              className="shrink-0 text-zinc-500 hover:text-zinc-300 transition-colors bg-black/20 rounded p-0.5"
            >
              <X className="w-4 h-4" />
            </button>
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}
