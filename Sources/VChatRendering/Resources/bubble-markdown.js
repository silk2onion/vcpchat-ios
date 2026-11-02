// Markdown is confined to the visual island; native conversation text stays native.
(() => {
    const protectedTags = 'script,style,pre,code,textarea,svg,math,kbd,samp,option';
    const blockTags = 'div,p,h1,h2,h3,h4,h5,h6,ul,ol,li,table,blockquote,section,article,pre';
    const blockMarkdown = /(?:^|\n)\s{0,3}(?:#{1,6}\s|[-+*]\s|\d+[.)]\s|```|~~~|>\s)|\n\s*\|?\s*:?-{3,}/;
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
})();
