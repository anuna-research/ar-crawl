# Extract Content with Specific CSS Classes

## Requirement

Jordan is reading documentation where only certain sections (marked with class="section") are relevant. They want to extract just those sections, ignoring sidebars and navigation.

## Workflow

```bash
# Fetch the documentation page
ar-crawl crawl https://example.com/docs \
  --output docs.json

# Extract content from specific class
ar-crawl extract docs.json \
  --format json \
  --fields '{"section_title": "//div[@class=\"section\"]//h2/text()", "section_text": "//div[@class=\"section\"]//p/text()"}' \
  --output sections.json

# View formatted results
cat sections.json | jq '.'
```

## Expected Outcome

JSON with only targeted content:
```json
{
  "data": [{
    "section_title": "Installation",
    "section_text": ["Follow these steps...", "Run the command..."]
  }, {
    "section_title": "Configuration",
    "section_text": ["Edit your config file...", "Set the following options..."]
  }]
}
```

Jordan gets clean, focused data without page clutter.

## Validates Understanding

- XPath predicates `[@class="section"]` filter by CSS class
- Hierarchical traversal: finding h2 and p elements within divs
- Precise targeting reduces noise in extracted data
- Browser DevTools can reveal class names for targeting
