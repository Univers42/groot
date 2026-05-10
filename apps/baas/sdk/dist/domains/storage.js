import { routes } from '../core/routes.js';
export class StorageClient {
    http;
    constructor(http) {
        this.http = http;
    }
    presign(input) {
        return this.http.request(routes.storage.sign(input.bucket, input.key), {
            method: 'POST',
            body: {
                method: input.method ?? 'PUT',
                contentType: input.contentType,
            },
        });
    }
}
