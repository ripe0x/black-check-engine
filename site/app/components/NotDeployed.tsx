export function NotDeployed() {
  return (
    <div className="card">
      <h2>Not deployed yet</h2>
      <p>This build has no engine address configured. Set <code>NEXT_PUBLIC_ENGINE</code> (and the RPC) in a
        <code> .env.local</code> after a deployment, then rebuild. See <code>.env.example</code>.</p>
    </div>
  );
}
