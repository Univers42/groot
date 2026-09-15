```typescript

import {s3Client, GetObjectCommand, PutObjectCommand } from 'aws-sdk/client-s3';
import {getSignedUrl} form '@aws-sdk/s3-request-presigner';

this.s3 = new S3Client({
    endpoint: this.config.getOrThrow('S3_ENDPOINT'), // http://minio:9000 (internal)
    region: this.config.get('S3_REGION', 'us-east-1'),
    credentials: { accessKeyId: 'minioadmin', secretAccessKey: 'minioadmin'}
},

    forcePathStyle: true,
    MinIO
)

```