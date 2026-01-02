# Extract Contact Information

## Requirement

Jordan needs to collect contact details (emails, phone numbers, names) from a contact page for their records.

## Workflow

```bash
# Fetch the contact page
ar-crawl crawl https://example.com/contact \
  --output contact.json

# Extract structured contact details
ar-crawl extract contact.json \
  --format json \
  --fields '{"email": "//a[contains(@href, \"mailto:\")]/@href", "phone": "//a[contains(@href, \"tel:\")]/@href", "name": "//div[@class=\"contact-person\"]//h3/text()"}' \
  --output contacts.json

# View the contacts
cat contacts.json | jq '.data[]'
```

## Expected Outcome

Structured contact data:
```json
{
  "email": "mailto:hello@example.com",
  "phone": "tel:+1-555-0123",
  "name": "John Smith"
}
{
  "email": "mailto:support@example.com",
  "phone": "tel:+1-555-0456",
  "name": "Jane Doe"
}
```

Jordan has clean, structured contact information ready for use.

## Validates Understanding

- XPath `contains()` function for pattern matching
- Extracting links by protocol (mailto:, tel:)
- Combining multiple extraction strategies in one query
- Real-world data extraction for practical use case
