# Later phase: keyless deploy from GitHub

This phase is part of the project. It is not built yet, on purpose. The site has to be proved from the laptop first. The trust rule is the piece that has already failed a deploy in another cloud when it was copied from an old guide.

## What it will do

A push to `main` updates the live site. GitHub Actions assumes an Identity and Access Management (IAM) role. The sign-in is OpenID Connect. GitHub holds no access key and no secret key.

The role can upload to this one bucket. It cannot delete the bucket, change the CloudFront distribution, or touch the rest of the account.

## The rule that already cost a failed deploy

Before the trust policy is written, read the token subject GitHub actually sends. New repositories put permanent owner and repository ids in that subject. A name-only subject (`repo:OWNER/NAME:ref:refs/heads/main`) is the old shape, and it will not match.

Write the subject down in the private findings log. Do not copy it out of a blog post.

## What "done" means for this phase

- The workflow uploads with `aws s3 sync --delete`, the same command the laptop script uses.
- A missing role stops the job at sign-in, before any upload.
- The first call that needs the new role retries, because a new grant is not instant.
- No key file and no account id is stored in the repository or in the workflow log.
