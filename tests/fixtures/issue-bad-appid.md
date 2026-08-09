### Application id

claims-app

### manifest.yaml (infrastructure — Platform Operations owned)

```yaml
apiVersion: platform.group.example/v1
kind: AppClaim
metadata:
  appId: wrong-app
  bu: bu1
  environments: [dev]
components:
  - type: ack
    claimSchema: ack/v1
    name: claims-cluster
    size: small
    namespaces: [claims-app]
  - type: oss
    claimSchema: oss/v1
    name: claims-documents
    size: standard
    versioning: true
    prefixes: ["incoming/", "reports/"]
```

### access.yaml (identity and access — Security Assurance owned)

```yaml
apiVersion: platform.group.example/v1
kind: AccessClaim
metadata:
  appId: wrong-app
  bu: bu1
workloadIdentity:
  - name: claims-api
    namespace: claims-app
    serviceAccount: claims-api
    resource: claims-documents
    prefix: incoming/
    level: readwrite
userAccess:
  - name: claims-reader
    group: GRP-BU1-CLAIMS-READER
    resource: claims-documents
    prefix: reports/
    level: read
```
