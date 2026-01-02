# Save Data as CSV for Spreadsheets

## Requirement

Jordan is comparing products from a website. They want to extract a table of product names and prices into a spreadsheet for analysis.

## Workflow

```bash
# Fetch the products page
ar-crawl crawl https://example.com/products \
  --output products.json

# Extract table data as CSV
ar-crawl extract products.json \
  --format csv \
  --fields '{"product_name": "//table//tr/td[1]/text()", "price": "//table//tr/td[2]/text()"}' \
  --output products.csv

# View or open in spreadsheet software
cat products.csv
```

## Expected Outcome

CSV file:
```csv
product_name,price
Widget Pro,29.99
Super Gadget,49.99
Basic Tool,19.99
```

Jordan can now open `products.csv` in Excel, Google Sheets, or Numbers for further analysis.

## Validates Understanding

- Output format (`--format csv`) changes structure for different use cases
- CSV is ideal for tabular data and spreadsheet import
- XPath table navigation with positional selectors `td[1]`, `td[2]`
- Same extraction logic works across different output formats
