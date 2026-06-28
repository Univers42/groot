# 04 — Security and IAM

> **Conceptual / unenforced locally.** DynamoDB Local does not enforce IAM authentication or authorization. Any credentials (including `AWS_ACCESS_KEY_ID=local`) are accepted and no permissions are checked. Everything in this file describes the **real AWS IAM model** that applies in production. Use this as a reference for writing IAM policies before deploying.

DynamoDB security in AWS is entirely IAM-driven: there is no database-level user/password system. Access is granted through identity-based IAM policies attached to users, roles, or groups. This file explains the action vocabulary, resource ARN format, fine-grained conditions, and gives a ready-to-use least-privilege example.

---

## The IAM model in one paragraph

When an AWS principal (an EC2 instance role, a Lambda execution role, an ECS task role) calls DynamoDB, AWS evaluates all attached IAM policies. If no policy explicitly `Allow`s the requested action on the requested resource, the call is denied. `Deny` statements override any `Allow`. DynamoDB has no concept of database users, roles, or row-level SQL grants — access control is entirely outside the database, in IAM.

---

## DynamoDB IAM action vocabulary

| Action | What it permits |
|---|---|
| `dynamodb:GetItem` | Single-item read by primary key |
| `dynamodb:PutItem` | Write or replace an item |
| `dynamodb:UpdateItem` | Partial update of an existing item |
| `dynamodb:DeleteItem` | Delete an item |
| `dynamodb:Query` | Range query (partition key required) |
| `dynamodb:Scan` | Full-table or full-index scan |
| `dynamodb:BatchGetItem` | Read up to 100 items by key in one request |
| `dynamodb:BatchWriteItem` | Write or delete up to 25 items in one request |
| `dynamodb:DescribeTable` | Read table metadata |
| `dynamodb:ListTables` | List all tables in the account/region |
| `dynamodb:CreateTable` | Create a new table |
| `dynamodb:DeleteTable` | Drop a table (irreversible) |
| `dynamodb:UpdateTable` | Modify billing mode, add/remove GSIs |
| `dynamodb:TransactGetItems` | Atomic multi-item read |
| `dynamodb:TransactWriteItems` | Atomic multi-item write (includes ConditionCheck) |

Grant the minimum set your application actually needs. A read-only API service typically needs only `GetItem` + `Query`.

---

## Resource ARN format

IAM `Resource` blocks use ARNs to scope permissions to specific tables and indexes.

### Table ARN

```
arn:aws:dynamodb:<region>:<account-id>:table/<TableName>
```

Example:

```
arn:aws:dynamodb:us-east-1:123456789012:table/orders
```

### Index ARN (for query access to a GSI or LSI)

```
arn:aws:dynamodb:<region>:<account-id>:table/<TableName>/index/<IndexName>
```

Example:

```
arn:aws:dynamodb:us-east-1:123456789012:table/orders/index/status-order-index
```

**Important:** To allow `dynamodb:Query` on a GSI, you must include the index ARN in the `Resource` list, not just the table ARN. The table ARN alone does not grant access to its indexes.

---

## Least-privilege IAM policy example

A backend API that reads orders for authenticated users and writes new orders, but cannot delete or scan:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OrdersReadWrite",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query"
      ],
      "Resource": [
        "arn:aws:dynamodb:us-east-1:123456789012:table/orders",
        "arn:aws:dynamodb:us-east-1:123456789012:table/orders/index/status-order-index"
      ]
    }
  ]
}
```

No `dynamodb:Scan`, no `dynamodb:DeleteItem`, no `dynamodb:DeleteTable`. If the application is compromised, an attacker cannot dump or drop the table.

---

## Fine-grained access control — `dynamodb:LeadingKeys`

DynamoDB supports an IAM condition key that restricts which **partition key values** a caller can access. This is called fine-grained access control (FGAC) and is the closest DynamoDB equivalent to row-level security.

**Use case:** a multi-tenant app where each user should only read their own orders. The user's ID is available as a claim in a Cognito identity pool.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OwnOrdersOnly",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/orders",
      "Condition": {
        "ForAllValues:StringEquals": {
          "dynamodb:LeadingKeys": ["${cognito-identity.amazonaws.com:sub}"]
        }
      }
    }
  ]
}
```

`${cognito-identity.amazonaws.com:sub}` is resolved at runtime to the authenticated user's identity. The caller cannot read or write items belonging to a different `customer_id`, even if they know the key.

### Other DynamoDB IAM condition keys

| Condition key | What it restricts |
|---|---|
| `dynamodb:LeadingKeys` | Partition key values the caller can access |
| `dynamodb:Attributes` | Which attribute names can be read or written |
| `dynamodb:Select` | Whether `ALL_ATTRIBUTES`, `SPECIFIC_ATTRIBUTES`, or `COUNT` may be used |
| `dynamodb:ReturnValues` | Which `ReturnValues` options are permitted |

---

## Denying dangerous operations explicitly

Prefer `Allow` with minimal actions over broad `Allow` + selective `Deny`. But for irreversible operations like table deletion, an explicit `Deny` adds a safety layer regardless of other policies:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NeverDeleteTable",
      "Effect": "Deny",
      "Action": "dynamodb:DeleteTable",
      "Resource": "*"
    },
    {
      "Sid": "NeverScan",
      "Effect": "Deny",
      "Action": "dynamodb:Scan",
      "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/orders"
    }
  ]
}
```

A `Deny` statement always wins, even if another policy grants the action.

---

## What DynamoDB Local ignores

DynamoDB Local (the Java jar running in `mini-baas-dynamodb-local`) does not implement the IAM enforcement layer:

| Production behavior | Local behavior |
|---|---|
| Credentials validated by AWS STS | Any non-empty string accepted |
| IAM policies evaluated per call | No evaluation — all calls succeed |
| `dynamodb:LeadingKeys` enforced | Not enforced — all partition keys accessible |
| VPC endpoint isolation | N/A — Local binds to a plain TCP port |
| CloudTrail audit log per API call | No audit log |
| Encryption at rest (KMS) | No encryption |

This means your development workflow never fails due to missing IAM permissions — but it also means you must test your IAM policies in a real AWS account (or a policy simulator) before deploying. The policy examples above are correct for production but will have no effect against Local.

---

## IAM policy simulator

Before deploying a policy, validate it with the AWS Policy Simulator (requires real AWS credentials):

```bash
# Test whether a simulated caller can call GetItem on your table
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/my-api-role \
  --action-names dynamodb:GetItem \
  --resource-arns arn:aws:dynamodb:us-east-1:123456789012:table/orders
```

---

## Gotchas / Docker notes

- **No credentials = no call.** Even against Local the CLI requires `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to be set — not for security, but because the CLI's signing code rejects empty values before the request is sent.
- **Index ARNs are separate from table ARNs.** A common mistake is granting `dynamodb:Query` on the table ARN and expecting GSI queries to work. They don't — add the index ARN explicitly.
- **`dynamodb:LeadingKeys` is a list.** Use `ForAllValues:StringEquals` (not `StringEquals`) so the condition is evaluated across all key values in a `BatchGetItem` request, not just the first.
- **KMS encryption.** For production tables add `"aws:kms:kms:*"` actions to your role if you use customer-managed KMS keys — otherwise `PutItem` calls fail with `AccessDeniedException` from KMS, which looks like a DynamoDB error.

---

## See also

- [00-connect.md](00-connect.md) — sidecar setup and `ddb` helper
- [01-tables-indexes.md](01-tables-indexes.md) — table and index ARN structure
- [02-crud-items.md](02-crud-items.md) — the operations IAM policies govern
- [03-query-scan.md](03-query-scan.md) — `Query` and `Scan` actions and when each is needed
