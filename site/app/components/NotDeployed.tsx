export function NotDeployed() {
  return (
    <div className="card">
      <h2>Not deployed yet</h2>
      <p>This build has no deployment record. Build with <code>NEXT_PUBLIC_DEPLOYMENT=&lt;env&gt;</code> after a deployment
        (see docs/DEPLOY.md).</p>
    </div>
  );
}
