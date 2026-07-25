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
MARKDOWN_HEADING = import("/components/markdown/Heading.haml")

# rubocop:disable Naming/ConstantName
Default = {
  a: MARKDOWN_LINK,
  blockquote: MARKDOWN_CALLOUT,
  code: MARKDOWN_INLINE_CODE,
  em: MARKDOWN_EMPHASIS,
  h1: MARKDOWN_HEADING,
  h2: MARKDOWN_HEADING,
  h3: MARKDOWN_HEADING,
  h4: MARKDOWN_HEADING,
  h5: MARKDOWN_HEADING,
  h6: MARKDOWN_HEADING,
  li: MARKDOWN_LIST_ITEM,
  ol: MARKDOWN_ORDERED_LIST,
  p: MARKDOWN_PARAGRAPH,
  pre: MARKDOWN_CODE_BLOCK,
  strong: MARKDOWN_STRONG,
  ul: MARKDOWN_LIST
}.freeze
# rubocop:enable Naming/ConstantName
