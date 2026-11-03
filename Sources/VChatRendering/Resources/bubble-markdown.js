// Markdown is confined to the visual island; native conversation text stays native.
(() => {
    const protectedTags = 'script,style,pre,code,textarea,svg,math,kbd,samp,option';
    const blockTags = 'div,p,h1,h2,h3,h4,h5,h6,ul,ol,li,table,blockquote,section,article,pre';
    const blockMarkdown = /(?:^|\n)\s{0,3}(?:#{1,6}\s|[-+*]\s|\d+[.)]\s|```|~~~|>\s)|\n\s*\|?\s*:?-{3,}/;
    // Marked handles code spans, HTML attributes and link destinations before
    // entering their contents. Only relax complete quoted CJK **...** tokens.
    marked.use({
        extensions: [{
            name: 'vcpCJKStrong', level: 'inline',
            start(source) { return source.indexOf('**'); },
            tokenizer(source) {
                const m = /^\*\*(?!\*)([^\n]+?)(?<![\\*])\*\*(?!\*)/u.exec(source);
                if (!m || /^\s|\s$/u.test(m[1]) || !/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(m[1]) || !/^["'“”‘’「」『』《》〈〉【】（）［］｛｝〔〕〖〗！？。，；：]|["'“”‘’「」『』《》〈〉【】（）［］｛｝〔〕〖〗！？。，；：]$/u.test(m[1])) return;
                return {type:'vcpCJKStrong',raw:m[0],tokens:this.lexer.inlineTokens(m[1])};
            },
            renderer(token) { return '<strong class="vcp-md-strong">' + this.parser.parseInline(token.tokens) + '</strong>'; }
        }],
        renderer: { strong(token) { return '<strong class="vcp-md-strong">' + this.parser.parseInline(token.tokens) + '</strong>'; } }
    });
    function transform(element) {
        if (element.matches(protectedTags)) return;
        if (!element.querySelector(blockTags + ',' + protectedTags)) {
            const original = element.innerHTML;
            // Inline parsing preserves existing HTML spans and attributes, and
            // keeps escaped HTML/code samples in their original literal domain.
            const rendered = blockMarkdown.test(element.textContent) && !element.matches('p,h1,h2,h3,h4,h5,h6,span,a,strong,em')
                ? marked.parse(original) : marked.parseInline(original);
            if (rendered !== original) element.innerHTML = rendered;
            return;
        }
        for (const child of Array.from(element.childNodes)) {
            if (child.nodeType === Node.ELEMENT_NODE) transform(child);
            else if (child.nodeType === Node.TEXT_NODE && /[*_`~\[]/.test(child.nodeValue)) {
                const template = document.createElement('template');
                const escaped = document.createElement('span');
                escaped.textContent = child.nodeValue;
                template.innerHTML = marked.parseInline(escaped.innerHTML);
                child.replaceWith(template.content);
            }
        }
    }
    window.VCPBubbleMarkdown = root => {
        for (const child of Array.from(root.children)) transform(child);
    };
    // A model-authored bubble can have a light background inside a dark app.
    // Keep the theme hue, but adjust only Markdown emphasis for readable contrast.
    window.VCPBubbleMarkdown.colorize = root => {
        const styles = new WeakMap(), backgrounds = new WeakMap();
        const style = node => { if (!styles.has(node)) styles.set(node,getComputedStyle(node)); return styles.get(node); };
        function rgba(value) {
            if (/^#[0-9a-f]{6}$/i.test(value.trim())) return [1,3,5].map(i=>parseInt(value.trim().slice(i,i+2),16)).concat(1);
            const parts = value.match(/[\d.]+/g)?.map(Number);
            return parts?.length >= 3 ? [parts[0],parts[1],parts[2],parts[3] ?? 1] : [0,0,0,0];
        }
        function background(node) {
            if (!node) return [255,255,255];
            if (backgrounds.has(node)) return backgrounds.get(node);
            const paint = rgba(style(node).backgroundColor), under = background(node.parentElement);
            const mixed = under.map((v,i)=>paint[i]*paint[3]+v*(1-paint[3]));
            backgrounds.set(node,mixed); return mixed;
        }
        const luminance = rgb => rgb.map(v=>{ v/=255; return v<=0.04045 ? v/12.92 : ((v+0.055)/1.055)**2.4; }).reduce((s,v,i)=>s+v*[0.2126,0.7152,0.0722][i],0);
        const contrast = (a,b) => (Math.max(a,b)+0.05)/(Math.min(a,b)+0.05);
        for (const node of root.querySelectorAll('strong.vcp-md-strong')) {
            const bg = luminance(background(node));
            let color = rgba(style(node).getPropertyValue('--vcp-md-emphasis')).slice(0,3);
            const target = bg > 0.18 ? 0 : 255;
            for (let n=0;n<18 && contrast(luminance(color),bg)<4.5;n++) color=color.map(v=>v*0.85+target*0.15);
            node.style.setProperty('color',`rgb(${color.map(Math.round).join(',')})`,'important');
        }
    };
})();
