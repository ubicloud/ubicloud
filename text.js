const marked = require("marked");

// Create a custom renderer
const customRenderer = new marked.Renderer();

// Extend the renderer to support a custom block
customRenderer.html = function (html) {
  // Check if the block starts with <xxxx>
  if (html.startsWith("<xxxx>") && html.endsWith("</xxxx>")) {
    // Extract the content between the tags
    const content = html.slice(6, -7).trim();
    // Render the custom block with <xxxx> wrapped around
    return `<xxxx>\n${content}\n</xxxx>`;
  }

  // Return the original HTML if it doesn't match
  return html;
};

// Set options for Marked.js to use the custom renderer
marked.setOptions({
  renderer: customRenderer,
});

// Test input
const markdownInput = `
This is normal markdown.

<xxxx>
Custom content inside the block.
</xxxx>
`;

// Parse Markdown with the custom renderer
const htmlOutput = marked(markdownInput);
console.log(htmlOutput);


const tokenizer = {
    html(src) {
      const match = src.match(/<think>([\s\S]*?)<\/think>/);
      if (match) {
        return {
          type: 'blockquote',
          raw: match[0],
          text: match[1].trim().split('\n').map(line => `> ${line}`).join('\n')
        };
      }
  
      // return false to use original codespan tokenizer
      return false;
    }
  };