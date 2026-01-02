# Extract a List of Links

## Requirement

Jordan finds a resource page with dozens of useful links. They want to collect all the links and their text so they can review and visit them later.

## Workflow

```bash
# Fetch the resource page
ar-crawl crawl https://example.com/resources \
  --output resources.json

# Extract all links with their text
ar-crawl extract resources.json \
  --format json \
  --fields '{"link_text": "//a/text()", "url": "//a/@href"}' \
  --output links.json

# View in readable format
cat links.json | jq '.data[] | "\(.link_text): \(.url)"'
```

## Expected Outcome

List of formatted output:
```
About Us: /about
Contact: /contact
Documentation: /docs
GitHub Repository: https://github.com/example/repo
```

Jordan can now process the links list or visit URLs systematically.

## Validates Understanding

- Extracting attributes with `@href` syntax
- Multiple results returned in the `data` array
- Piping to `jq` makes output more readable
- Can extract both text content and attributes simultaneously
