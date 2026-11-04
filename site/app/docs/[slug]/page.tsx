import { PAGES } from "../nav";
import { DocsShell } from "../Shell";
import { collectionMeta } from "../../lib/deployment";
import { pageMeta } from "../../lib/meta";

export const dynamicParams = false;
export const generateStaticParams = () => PAGES.filter((p) => p.slug).map((p) => ({ slug: p.slug }));

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params, page = PAGES.find((p) => p.slug === slug)!;
  return pageMeta(page.title, `${collectionMeta.game} docs, ${page.section}: ${page.title}.`, `/docs/${slug}/`);
}

export default async function DocsPage({ params }: { params: Promise<{ slug: string }> }) {
  return <DocsShell slug={(await params).slug} />;
}
