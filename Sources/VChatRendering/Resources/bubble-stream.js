// Same keyed DOM-diff approach as desktop VChat, confined to one sandboxed bubble.
(() => {
    const mount = document.createElement('div');
    document.body.appendChild(mount);
    const executed = new WeakMap();
    const epoch = window.VCPBubbleEpoch;
    let pending, frame, lifecycleStarted = false, lifecycleDelivered = false;
    // Model scripts run in the page world, while the renderer stays isolated.
    // Deliver their normal document-ready lifecycle once, after the final frame.
    function pageLifecycle(finish) {
        const bridge = document.createElement('script');
        bridge.textContent = `(() => {
            const key=Symbol.for('vcp.island.lifecycle');
            const state=window[key]||(window[key]={original:Object.getOwnPropertyDescriptor(document,'readyState'),done:false});
            if(state.done)return;
            if(!${finish}){Object.defineProperty(document,'readyState',{configurable:true,get:()=> 'loading'});return;}
            state.done=true;
            if(state.original)Object.defineProperty(document,'readyState',state.original);else delete document.readyState;
            document.dispatchEvent(new Event('DOMContentLoaded',{bubbles:true}));
            const images=Array.from(document.images).filter(image=>!image.complete);
            Promise.all(images.map(image=>new Promise(resolve=>{
                image.addEventListener('load',resolve,{once:true});image.addEventListener('error',resolve,{once:true});
            }))).then(()=>window.dispatchEvent(new Event('load')));
        })()`;
        document.head.appendChild(bridge); bridge.remove();
    }
    function apply() {
        frame = undefined;
        if (!pending) return;
        const {source,streaming} = pending; pending = undefined;
        const next = document.createElement('div');
        next.innerHTML = source;
        VCPBubbleMarkdown(next);
        morphdom(mount,next,{
            childrenOnly: true,
            getNodeKey: node => node.id || node.dataset?.vcpKey,
            onBeforeElUpdated: (from,to) => {
                if (from.isEqualNode(to)) return false;
                if (from.tagName === 'DETAILS') to.open = from.open;
                if (from === document.activeElement && 'value' in from) to.value = from.value;
                return true;
            }
        });
        VCPBubbleMarkdown.colorize(mount);
        // A partial <script> is parsed inertly. Activate only fully received
        // inline scripts, once; further text chunks keep the same live nodes.
        const closed = new Set();
        const pattern = /<script\b(?:"[^"]*"|'[^']*'|[^'">])*>[\s\S]*?<\/script\s*>/gi;
        for (const match of source.matchAll(pattern)) {
            const template = document.createElement('template'); template.innerHTML = match[0];
            const script = template.content.querySelector('script');
            if (script) closed.add(script.textContent);
        }
        if (!lifecycleStarted) { pageLifecycle(false); lifecycleStarted = true; }
        for (const script of mount.querySelectorAll('script')) {
            const key = JSON.stringify([script.type,script.textContent]);
            if (script.src || !closed.has(script.textContent) || executed.get(script) === key) continue;
            const active = document.createElement('script');
            for (const attribute of script.attributes) active.setAttribute(attribute.name,attribute.value);
            active.textContent = script.textContent; executed.set(active,key); script.replaceWith(active);
        }
        if (!streaming && !lifecycleDelivered) { pageLifecycle(true); lifecycleDelivered = true; }
    }
    window.VCPBubbleStream = {
        update(source,streaming,requestEpoch) {
            if (requestEpoch !== epoch) return;
            pending = {source,streaming};
            if (!streaming) { if (frame !== undefined) cancelAnimationFrame(frame); apply(); }
            else if (frame === undefined) frame = requestAnimationFrame(apply);
        }
    };
})();
