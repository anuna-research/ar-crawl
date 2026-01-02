# Test Extraction Incrementally

## Requirement

Jordan isn't sure what XPath to use for a complex page. They want to build up their extraction query gradually, testing each field before adding more.

## Workflow

```bash
# Fetch the page once
ar-crawl crawl https://example.com/data \
  --output test-page.json

# Start simple: just get the page title
ar-crawl extract test-page.json \
  --format json \
  --fields '{"title": "//title/text()"}' \
  --output test-title.json

# Verify it worked
cat test-title.json

# Add more fields incrementally
ar-crawl extract test-page.json \
  --format json \
  --fields '{"title": "//title/text()", "headings": "//h2/text()"}' \
  --output test-headings.json

# Check again
cat test-headings.json

# Build up to complete extraction
ar-crawl extract test-page.json \
  --format json \
  --fields '{"title": "//title/text()", "headings": "//h2/text()", "paragraphs": "//p/text()"}' \
  --output full-data.json
```

## Expected Outcome

Confidence building through successful iterations. Each step confirms the previous XPath works before adding complexity.

Final output contains all desired fields:
```json
{
  "data": [{
    "title": "Page Title",
    "headings": ["Section 1", "Section 2"],
    "paragraphs": ["Text 1", "Text 2", "Text 3"]
  }]
}
```

## Validates Understanding

- Crawl once, extract many times (no need to re-fetch)
- XPath queries can be refined without hitting the server again
- Start simple, add complexity gradually
- Testing small pieces makes debugging easier
