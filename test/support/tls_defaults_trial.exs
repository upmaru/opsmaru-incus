# Process-local ambient OpenSSL defaults: never mutate the parent suite's env.
[root] = System.argv()
config = Path.join(root, "ambient-defaults.cnf")

File.write!(
  config,
  "[req]\ndistinguished_name=dn\nx509_extensions=v3_ca\n[dn]\n[v3_ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
)

System.put_env("OPENSSL_CONF", config)
Opsmaru.TestSupport.TLSIdentity.generate(root, "ambient", "localhost")
IO.puts("Explicit fixture configuration isolated from ambient CA extensions")
