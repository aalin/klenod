MARKDOWN_LINK = import("/components/markdown/Link.haml")
MARKDOWN_CALLOUT = import("/components/markdown/Callout.haml")
MARKDOWN_CODE_BLOCK = import("/components/markdown/CodeBlock.haml")
MARKDOWN_PARAGRAPH = import("/components/markdown/Paragraph.haml")
MARKDOWN_LIST = import("/components/markdown/List.haml")
MARKDOWN_ORDERED_LIST = import("/components/markdown/OrderedList.haml")
MARKDOWN_LIST_ITEM = import("/components/markdown/ListItem.haml")
MARKDOWN_INLINE_CODE = import("/components/markdown/InlineCode.haml")
MARKDOWN_STRONG = import("/components/markdown/Strong.haml")
MARKDOWN_EMPHASIS = import("/components/markdown/Emphasis.haml")
MarkdownHeading = import("/components/markdown/Heading.rb")

# rubocop:disable Naming/ConstantName
Default = {
  a: MARKDOWN_LINK,
  blockquote: MARKDOWN_CALLOUT,
  code: MARKDOWN_INLINE_CODE,
  em: MARKDOWN_EMPHASIS,
  h1: MarkdownHeading::H1,
  h2: MarkdownHeading::H2,
  h3: MarkdownHeading::H3,
  h4: MarkdownHeading::H4,
  h5: MarkdownHeading::H5,
  h6: MarkdownHeading::H6,
  li: MARKDOWN_LIST_ITEM,
  ol: MARKDOWN_ORDERED_LIST,
  p: MARKDOWN_PARAGRAPH,
  pre: MARKDOWN_CODE_BLOCK,
  strong: MARKDOWN_STRONG,
  ul: MARKDOWN_LIST
}.freeze
# rubocop:enable Naming/ConstantName
