type KlenodAssetVariant = {
  src: string;
  width?: number;
  height?: number;
  descriptor?: string;
  contentType?: string;
};

type KlenodImageAsset = {
  src: string;
  width: number;
  height: number;
  contentType: string;
  variants: KlenodAssetVariant[];
  srcset?: string;
  sizes?: string;
};

type KlenodSvgAsset = {
  src: string;
  width?: number;
  height?: number;
  contentType: "image/svg+xml";
};

declare function h(
  type: string | CustomElementConstructor | ((attrs: Record<string, unknown> | null, ...children: unknown[]) => Node),
  attrs: any,
  ...children: unknown[]
): Node;

declare function Fragment(attrs: any, ...children: unknown[]): DocumentFragment;

declare module "*.css" {
  const stylesheet: CSSStyleSheet;
  export default stylesheet;
}

declare module "*.svg" {
  const asset: KlenodSvgAsset;
  export default asset;
}

declare module "*.png" {
  const asset: KlenodImageAsset;
  export default asset;
}

declare module "*.jpg" {
  const asset: KlenodImageAsset;
  export default asset;
}

declare module "*.jpeg" {
  const asset: KlenodImageAsset;
  export default asset;
}

declare module "*.webp" {
  const asset: KlenodImageAsset;
  export default asset;
}

declare module "*.gif" {
  const asset: KlenodImageAsset;
  export default asset;
}

declare namespace JSX {
  type Element = Node;
  type ElementType = string | CustomElementConstructor | ((attrs: any, ...children: unknown[]) => Node);

  interface ElementChildrenAttribute {
    children: {};
  }

  interface IntrinsicElements {
    [name: string]: any;
  }
}
