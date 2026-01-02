# Extract Image URLs

## Requirement

Jordan finds a gallery page with photos they want to reference or download later. They need the image URLs and descriptions.

## Workflow

```bash
# Fetch the gallery page
ar-crawl crawl https://example.com/gallery \
  --output gallery.json

# Extract image URLs and alt text
ar-crawl extract gallery.json \
  --format json \
  --fields '{"image_url": "//img/@src", "alt_text": "//img/@alt"}' \
  --output images.json

# View the results
cat images.json | jq '.data[]'
```

## Expected Outcome

JSON with image data:
```json
{
  "image_url": "/images/photo1.jpg",
  "alt_text": "Sunset over mountains"
}
{
  "image_url": "/images/photo2.jpg",
  "alt_text": "City skyline at night"
}
```

Jordan now has a list of all images with their descriptions, ready for downloading or cataloging.

## Validates Understanding

- Images have attributes (`src`, `alt`) that can be extracted
- Same extraction pattern applies to different HTML elements
- Multiple attributes from same element can be captured together
- Image URLs can be used with download tools like `wget` or `curl`
