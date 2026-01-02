# First-Time User

## Who They Are

Jordan Taylor is discovering ar-crawl for the first time. They're a hobbyist, student, or casual web user working on personal projects, learning exercises, or small assignments. Jordan has basic command line familiarity but is new to web scraping tools.

**Background:**
- Personal use cases: saving articles offline, collecting product comparisons, school projects
- No prior experience with XPath or web scraping
- Learns best through hands-on experimentation with immediate feedback
- Expects software to be intuitive with gentle learning curves

## Daily Context

Jordan's typical workflow involves:
- Opening Terminal when needed for specific tasks
- Copy-pasting commands from tutorials or documentation
- Viewing results in text editors or spreadsheet software
- Iterating through trial-and-error to understand new tools

When encountering ar-crawl, Jordan is likely solving an immediate problem: they need data from a website and manual copy-paste is too tedious. They're looking for the fastest path from "what is this tool?" to "I got my data."

## Technical Capabilities

**Can do:**
- Navigate directories with `cd` and `ls`
- Run commands with arguments and flags
- Copy-paste and modify example commands
- View files with `cat` or open in text editors
- Understand JSON and CSV file formats conceptually
- Use basic tools like `jq` if given examples

**Cannot do (yet):**
- Write XPath expressions from scratch
- Understand complex command chaining
- Debug cryptic error messages independently
- Navigate man pages or technical documentation efficiently
- Reason about HTML document structure without visual aids

**Learning style:**
- Needs working examples that can be copied and modified
- Prefers seeing output immediately to confirm understanding
- Builds mental models through pattern recognition
- Gets frustrated by errors without clear recovery paths

## Needs and Expectations

**From ar-crawl:**
1. **Obviousness:** The two-step workflow (crawl → extract) should be self-evident
2. **Feedback:** Each command should produce visible output confirming it worked
3. **Simplicity:** Start with single pages before multi-page crawls
4. **Progressiveness:** Early successes build confidence for harder tasks
5. **Forgiveness:** Errors should be informative, not punishing

**Success looks like:**
- Running first command and seeing a file created
- Opening that file and recognizing the data they wanted
- Modifying the command slightly and getting expected changes
- Feeling capable of solving their next extraction task independently

**Failure looks like:**
- No output or error messages they can't interpret
- Getting data but in an unrecognizable format
- XPath returning nothing without understanding why
- Feeling like they need a Computer Science degree to continue

## Mental Model Development

Jordan needs to build these concepts in order:

1. **Commands create files** (crawl makes .json, extract makes output)
2. **Files contain web page data** (the HTML is stored locally now)
3. **XPath selects parts of that data** (like search terms for page elements)
4. **Different formats serve different uses** (JSON for code, CSV for spreadsheets)

Each happy path flow should reinforce these concepts while adding one new idea at a time.
