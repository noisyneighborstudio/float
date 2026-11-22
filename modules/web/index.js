// Web module for Float: lightweight browser frame and top-edge drag strip placeholders
// for the web dev loop and automated Contract tests.
export const abi = 1;
export const roster = {
  'float-browser': { snapshot: false },
  'float-drag-strip': { snapshot: false },
};

export function create(tag, element, json) {
  const props = JSON.parse(json);
  const root = element.shadowRoot ?? element.attachShadow({ mode: 'open' });
  const box = document.createElement('div');
  if (tag === 'float-drag-strip') {
    box.style.cssText = 'width:100%;height:100%;background:rgba(0,0,0,0.45);opacity:0;transition:opacity 150ms ease;';
    box.addEventListener('mouseenter', () => { box.style.opacity = '1'; });
    box.addEventListener('mouseleave', () => { box.style.opacity = '0'; });
  } else {
    box.style.cssText = 'width:100%;height:100%;background:#000;';
    box.dataset.mode = props.mode ?? 'home';
  }
  root.replaceChildren(box);
  return { tag, box };
}

export function setProps(h, json) {
  const props = JSON.parse(json);
  if (h.tag === 'float-browser') {
    h.box.dataset.mode = props.mode ?? 'home';
  }
}

export function snapshot() {}
export function destroy() {}
