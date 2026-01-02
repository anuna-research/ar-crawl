# Extract Text from a Single Page

## Requirement

Jordan finds a blog article they want to save. They need to extract the title and main content paragraphs to a file they can read later.

## Workflow

```bash
# Fetch and save the page
ar-crawl crawl https://example.com/blog/article \
  --output article.json

# Extract title and content
ar-crawl extract article.json \
  --format json \
  --fields '{"title": "//h1/text()", "content": "//article//p/text()"}' \
  --output article-data.json

# View the extracted data
cat article-data.json
```

## Expected Outcome

A JSON file containing:
```json
{
  "data": [{
    "title": "Article Title Here",
    "content": ["Paragraph 1 text", "Paragraph 2 text", ...]
  }]
}
```

Jordan can now read the content offline or process it further.

## Validates Understanding

- Two-step process: crawl stores HTML, extract pulls data from it
- Files are created in the current directory
- XPath syntax basics: `//h1/text()` gets text from h1 tags
- Output is immediately viewable with common tools
