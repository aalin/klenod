MARKDOWN_LINK = import("/components/MarkdownLink.haml")
MARKDOWN_CALLOUT = import("/components/MarkdownCallout.haml")
MARKDOWN_CODE_BLOCK = import("/components/MarkdownCodeBlock.haml")
MARKDOWN_PARAGRAPH = import("/components/MarkdownParagraph.haml")
MARKDOWN_LIST = import("/components/MarkdownList.haml")
MARKDOWN_ORDERED_LIST = import("/components/MarkdownOrderedList.haml")
MARKDOWN_LIST_ITEM = import("/components/MarkdownListItem.haml")
MARKDOWN_INLINE_CODE = import("/components/MarkdownInlineCode.haml")
MARKDOWN_STRONG = import("/components/MarkdownStrong.haml")
MARKDOWN_EMPHASIS = import("/components/MarkdownEmphasis.haml")

# rubocop:disable Naming/ConstantName
Default = {
  a: MARKDOWN_LINK,
  blockquote: MARKDOWN_CALLOUT,
  code: MARKDOWN_INLINE_CODE,
  em: MARKDOWN_EMPHASIS,
  li: MARKDOWN_LIST_ITEM,
  ol: MARKDOWN_ORDERED_LIST,
  p: MARKDOWN_PARAGRAPH,
  pre: MARKDOWN_CODE_BLOCK,
  strong: MARKDOWN_STRONG,
  ul: MARKDOWN_LIST
}.freeze
# rubocop:enable Naming/ConstantName
