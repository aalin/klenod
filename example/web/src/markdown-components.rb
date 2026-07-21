MARKDOWN_LINK = import("/components/MarkdownLink.haml")
MARKDOWN_CALLOUT = import("/components/MarkdownCallout.haml")
MARKDOWN_CODE_BLOCK = import("/components/MarkdownCodeBlock.haml")

# rubocop:disable Naming/ConstantName
Default = {
  a: MARKDOWN_LINK,
  blockquote: MARKDOWN_CALLOUT,
  pre: MARKDOWN_CODE_BLOCK
}.freeze
# rubocop:enable Naming/ConstantName
