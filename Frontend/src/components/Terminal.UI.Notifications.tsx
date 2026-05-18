import React from 'react';
import { makeStyles } from '@fluentui/react-components';
import { motion, AnimatePresence } from 'motion/react';
import { useAppStore } from '../System.Store';
import { CheckCircle, Info, AlertTriangle, XCircle, X } from 'lucide-react';

const useStyles = makeStyles({
  root: {
    position: 'fixed',
    top: '16px',
    right: '16px',
    zIndex: 200,
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
    maxWidth: '384px',
    width: '100%',
    pointerEvents: 'none',
  },
  toast: {
    borderRadius: '12px',
    padding: '12px',
    display: 'flex',
    alignItems: 'flex-start',
    gap: '12px',
    pointerEvents: 'auto',
    boxShadow: '0 25px 50px -12px rgba(0,0,0,0.5)',
  },
  icon: {
    flexShrink: 0,
    marginTop: '2px',
  },
  message: {
    flex: 1,
    fontSize: '14px',
    fontWeight: '500',
    lineHeight: '1.3',
  },
  closeBtn: {
    flexShrink: 0,
    color: 'rgba(161,161,170,1)',
    backgroundColor: 'rgba(0,0,0,0.2)',
    borderRadius: '4px',
    padding: '2px',
    border: 'none',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    ':hover': {
      color: 'rgba(212,212,216,1)',
    },
  },
});

export default function Notifications() {
  const { notifications, removeNotification } = useAppStore();
  const styles = useStyles();

  const getIcon = (type: string) => {
    switch (type) {
      case 'success': return <CheckCircle style={{ width: 16, height: 16, color: '#34d399' }} />;
      case 'warn':    return <AlertTriangle style={{ width: 16, height: 16, color: '#fbbf24' }} />;
      case 'error':   return <XCircle style={{ width: 16, height: 16, color: '#f87171' }} />;
      default:        return <Info style={{ width: 16, height: 16, color: '#60a5fa' }} />;
    }
  };

  return (
    <div className={styles.root}>
      <AnimatePresence>
        {notifications.map((notification) => (
          <motion.div
            key={notification.id}
            initial={{ opacity: 0, x: 20, scale: 0.95 }}
            animate={{ opacity: 1, x: 0, scale: 1 }}
            exit={{ opacity: 0, x: 20, scale: 0.95 }}
            className={`mica-panel mica-border ${styles.toast}`}
          >
            <div className={styles.icon}>{getIcon(notification.type)}</div>
            <div className={`text-shadow-mica ${styles.message}`}>
              {notification.message}
            </div>
            <button
              onClick={() => removeNotification(notification.id)}
              className={styles.closeBtn}
            >
              <X style={{ width: 16, height: 16 }} />
            </button>
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  );
}
