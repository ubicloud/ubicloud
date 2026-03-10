package main

import (
	"bytes"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/gomarkdown/markdown/ast"
	"github.com/gomarkdown/markdown/parser"
)

func main() {
	// Parse command-line flags
	previousFile := flag.String("previous", "", "Path to previous issue body markdown file")
	templateFile := flag.String("template", "", "Path to issue template file")
	backupBranch := flag.String("backup-branch", "", "Backup branch name to inject")
	date := flag.String("date", "", "Date to inject (YYYYMMDD)")
	commitAnalysis := flag.String("commit-analysis", "", "Commit analysis text from Claude")
	outputFile := flag.String("output", "", "Path to write new issue body")
	flag.Parse()

	// Validate required flags
	if *previousFile == "" || *templateFile == "" || *backupBranch == "" || *date == "" || *outputFile == "" {
		log.Fatal("All flags are required: --previous, --template, --backup-branch, --date, --output")
	}

	// Read previous issue body
	previousBody, err := os.ReadFile(*previousFile)
	if err != nil {
		log.Printf("Warning: Could not read previous issue file: %v", err)
		previousBody = []byte("")
	}

	// Extract pending items from previous issue
	pendingItems := extractPendingItems(string(previousBody))
	log.Printf("Extracted %d pending items from previous issue", len(pendingItems))

	// Read template
	templateBody, err := os.ReadFile(*templateFile)
	if err != nil {
		log.Fatalf("Failed to read template file: %v", err)
	}

	// Inject values into template
	newIssueBody := injectIntoTemplate(string(templateBody), pendingItems, *backupBranch, *date, *commitAnalysis)

	// Write output
	err = os.WriteFile(*outputFile, []byte(newIssueBody), 0644)
	if err != nil {
		log.Fatalf("Failed to write output file: %v", err)
	}

	log.Printf("Successfully generated new issue body at %s", *outputFile)
}

// extractPendingItems extracts unchecked items from <!-- PENDING_ITEMS --> block
func extractPendingItems(previousBody string) []string {
	var items []string

	// Look for <!-- PENDING_ITEMS --> block
	startTag := "<!-- PENDING_ITEMS -->"
	endTag := "<!-- /PENDING_ITEMS -->"

	startIdx := strings.Index(previousBody, startTag)
	endIdx := strings.Index(previousBody, endTag)

	if startIdx == -1 || endIdx == -1 || endIdx <= startIdx {
		log.Println("No PENDING_ITEMS block found in previous issue")
		return items
	}

	log.Println("Found PENDING_ITEMS block")
	content := previousBody[startIdx+len(startTag) : endIdx]

	// Parse the content with markdown library to extract unchecked checkboxes
	items = extractUncheckedCheckboxes(content)

	log.Printf("Extracted %d unchecked items", len(items))
	return items
}

// extractUncheckedCheckboxes uses markdown parser to find unchecked task list items
func extractUncheckedCheckboxes(content string) []string {
	var items []string

	// Parse markdown to get list structure
	extensions := parser.CommonExtensions | parser.AutoHeadingIDs
	p := parser.NewWithExtensions(extensions)
	doc := p.Parse([]byte(content))

	// Walk the AST and find list items
	ast.WalkFunc(doc, func(node ast.Node, entering bool) ast.WalkStatus {
		if !entering {
			return ast.GoToNext
		}

		// Look for list items
		if listItem, ok := node.(*ast.ListItem); ok {
			// Extract the raw text content
			text := extractTextFromNode(listItem)
			text = strings.TrimSpace(text)

			// Check if it starts with [ ] (unchecked checkbox pattern)
			if strings.HasPrefix(text, "[ ]") {
				// Remove the [ ] prefix
				text = strings.TrimPrefix(text, "[ ]")
				text = strings.TrimSpace(text)

				if text != "" && !strings.HasPrefix(text, "<!--") {
					items = append(items, "- [ ] "+text)
				}
			}
		}

		return ast.GoToNext
	})

	return items
}

// extractTextFromNode recursively extracts text content from AST nodes
// Preserves markdown formatting like links, bold, code, etc.
func extractTextFromNode(node ast.Node) string {
	var buf bytes.Buffer

	ast.WalkFunc(node, func(n ast.Node, entering bool) ast.WalkStatus {
		switch v := n.(type) {
		case *ast.Text:
			if entering {
				buf.Write(v.Literal)
			}
		case *ast.Code:
			if entering {
				buf.WriteString("`")
				buf.Write(v.Literal)
				buf.WriteString("`")
			}
		case *ast.Link:
			if entering {
				buf.WriteString("[")
			} else {
				buf.WriteString("](")
				buf.Write(v.Destination)
				buf.WriteString(")")
			}
		case *ast.Emph:
			if entering {
				buf.WriteString("*")
			} else {
				buf.WriteString("*")
			}
		case *ast.Strong:
			if entering {
				buf.WriteString("**")
			} else {
				buf.WriteString("**")
			}
		case *ast.Hardbreak:
			if entering {
				buf.WriteString(" ")
			}
		case *ast.Softbreak:
			if entering {
				buf.WriteString(" ")
			}
		}

		return ast.GoToNext
	})

	return buf.String()
}

// injectIntoTemplate replaces placeholders in template and adds pending items
func injectIntoTemplate(template string, items []string, backupBranch, date, commitAnalysis string) string {
	// Replace placeholders
	result := strings.ReplaceAll(template, "{{BACKUP_BRANCH}}", backupBranch)
	result = strings.ReplaceAll(result, "{{DATE}}", date)
	result = strings.ReplaceAll(result, "{{COMMIT_ANALYSIS}}", commitAnalysis)

	// Format pending items within PENDING_ITEMS block
	var pendingItemsStr string
	if len(items) > 0 {
		itemsContent := strings.Join(items, "\n")
		pendingItemsStr = fmt.Sprintf("<!-- PENDING_ITEMS -->\n%s\n<!-- /PENDING_ITEMS -->", itemsContent)
	} else {
		pendingItemsStr = "<!-- PENDING_ITEMS -->\n<!-- No pending items from previous issue -->\n<!-- /PENDING_ITEMS -->"
	}

	// Replace pending items placeholder
	result = strings.ReplaceAll(result, "{{PENDING_ITEMS}}", pendingItemsStr)

	return result
}
