// Puente JSON {type, payload} entre React (WKWebView) y el shell SwiftUI.
// JS -> Swift: window.webkit.messageHandlers.chopshop.postMessage({type, payload, id?})
// Swift -> JS: window.chopshop.receive({type, payload, id?})
let seq = 0;
const waiting = new Map();
const listeners = new Set();

window.chopshop = {
  receive(msg) {
    if (msg.id && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
      return;
    }
    listeners.forEach((l) => l(msg));
  },
};

const host = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.chopshop;

export const send = (type, payload = {}) => {
  const h = host();
  if (h) h.postMessage({ type, payload });
};

export const request = (type, payload = {}) =>
  new Promise((resolve, reject) => {
    const h = host();
    if (!h) return reject(new Error("sin puente nativo"));
    const id = ++seq;
    waiting.set(id, resolve);
    h.postMessage({ type, payload, id });
    setTimeout(() => {
      if (waiting.delete(id)) reject(new Error("timeout"));
    }, 60000);
  });

export const on = (fn) => {
  listeners.add(fn);
  return () => listeners.delete(fn);
};
