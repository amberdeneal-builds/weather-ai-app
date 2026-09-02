"""Weather AI Lambda - minimal plumbing check.

Deliberately does not fetch real weather or call Bedrock yet. It writes one
item to the DynamoDB cache table and reads it back, which is enough to prove
the IAM role, VPC networking (via the DynamoDB gateway endpoint), and table
wiring built in terraform/ all actually work together. Real weather-lookup
and AI-insight logic replaces this once that's confirmed.
"""

import json
import os
import time
import uuid

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    cache_key = f"plumbing-check#{uuid.uuid4()}"
    now = int(time.time())

    table.put_item(
        Item={
            "cache_key": cache_key,
            "checked_at": now,
            "expires_at": now + 300,  # 5 minutes - exercises the table's TTL
            "message": "Lambda -> IAM role -> VPC endpoint -> DynamoDB round trip OK",
        }
    )

    response = table.get_item(Key={"cache_key": cache_key})
    item = response.get("Item")

    return {
        "statusCode": 200 if item else 500,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(item, default=str)
        if item
        else json.dumps({"error": "item not found after put_item"}),
    }
