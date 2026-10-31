# AWS Static Website Proof of Concept

A small business needs a fast, cheap, secure website with Hypertext Transfer Protocol Secure (HTTPS), its own name, no servers to maintain, and almost no monthly cost.

**Status:** the private bucket, the Origin Access Control, and the security-headers policy are in place. CloudFront isn't, because AWS refused to create the distribution until my account is verified. Once it is, re-run `./scripts/deploy.sh`; it reuses everything that's already there. The full walkthrough and screenshots will come after the site is up.

Part of [Cloud Projects](https://github.com/zsociety47/cloud-projects).

## What this pass will prove

The pages live in a private Simple Storage Service (S3) bucket. Visitors reach them through CloudFront, Amazon's content delivery network, using Origin Access Control (OAC). The bucket isn't public. The first deploy stops at the CloudFront hostname. A custom domain is added only after the domain is bought in the Route 53 console and a hosted zone already exists. The apex name will be the real site, and `www` will redirect to it.

## Names

| Thing | Value |
|---|---|
| Folder | `aws/01-aws-static-website-poc` |
| Profile | the name in `.env`, from `aws login` |
| Region | `us-east-1` for the bucket. The certificate, when there is one, stays in `us-east-1` because CloudFront requires it |
| Bucket | the name in `.env` |
| Tags | `lifetime=1d`, `owner=zeon`, `project=01-aws-static-website-poc`, `environment=poc`, and `created` |

### Run this as yourself

The names committed in this repository are this proof of concept. Leave them. Put your owner word in the copy you run. Bucket names must be unique across Amazon Web Services.

| Open this | Do this |
|---|---|
| [`.env.example`](.env.example) | Copy to `.env` (gitignored) before any script runs. Replace `yourname01` in `BUCKET_NAME`. |
| [`scripts/lib/config.sh`](scripts/lib/config.sh) | Change `OWNER_TAG` so the bucket is not tagged as mine. |

```bash
cp .env.example .env
```

## Later phase, still part of this project

A keyless deploy from GitHub is in scope and isn't built yet. GitHub Actions will assume an Identity and Access Management (IAM) role with OpenID Connect. No access key will be stored in GitHub. The trust rule will use the exact token subject GitHub prints, including the numeric owner and repository ids. See [docs/later-github-deploy.md](docs/later-github-deploy.md).

## What is here now

```
site/                     the same tracker pages as the Azure and Google Cloud proofs
scripts/deploy.sh         creates the bucket, Origin Access Control, and CloudFront, then uploads site/
scripts/www-redirect.js   sends www to the apex once a domain exists
scripts/lib/config.sh     loads .env, requires a profile, masks account ids
.env.example              the names. Copy to .env
docs/later-github-deploy.md
```

`verify.sh` is next, after CloudFront exists.
