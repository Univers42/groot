/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   crypto.service.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 20:22:36 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomBytes, scryptSync, createCipheriv, createDecipheriv } from 'node:crypto';

const ALGORITHM = 'aes-256-gcm';
const KEY_LENGTH = 32;
const IV_LENGTH = 16;
const SALT_LENGTH = 16;
const AUTH_TAG_LENGTH = 16;

export interface EncryptedPayload {
  encrypted: Buffer;
  iv: Buffer;
  tag: Buffer;
  salt: Buffer;
}

/**
 * AES-256-GCM encryption service.
 * Key is derived via scrypt from VAULT_ENC_KEY + per-record salt.
 */
@Injectable()
export class CryptoService {
  private readonly masterKey: string;

  constructor(config: ConfigService) {
    const key = config.getOrThrow<string>('VAULT_ENC_KEY');
    if (key.length < 16) {
      throw new Error('VAULT_ENC_KEY must be at least 16 characters');
    }
    this.masterKey = key;
  }

  encrypt(plaintext: string): EncryptedPayload {
    const salt = randomBytes(SALT_LENGTH);
    const key = scryptSync(this.masterKey, salt, KEY_LENGTH);
    const iv = randomBytes(IV_LENGTH);

    const cipher = createCipheriv(ALGORITHM, key, iv, { authTagLength: AUTH_TAG_LENGTH });
    const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();

    return { encrypted, iv, tag, salt };
  }

  decrypt(payload: EncryptedPayload): string {
    if (payload.iv.length !== IV_LENGTH || payload.salt.length !== SALT_LENGTH || payload.tag.length !== AUTH_TAG_LENGTH) {
      throw new Error('Invalid encrypted payload');
    }
    const key = scryptSync(this.masterKey, payload.salt, KEY_LENGTH);
    const decipher = createDecipheriv(ALGORITHM, key, payload.iv, { authTagLength: AUTH_TAG_LENGTH });
    decipher.setAuthTag(payload.tag);

    return Buffer.concat([decipher.update(payload.encrypted), decipher.final()]).toString('utf8');
  }
}
