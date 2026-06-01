/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   register-database.dto.ts                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Type } from 'class-transformer';
import {
  IsBoolean,
  IsEnum,
  IsNotEmpty,
  IsObject,
  IsOptional,
  IsString,
  MaxLength,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export const REGISTERABLE_ENGINES = [
  'postgresql',
  'mongodb',
  'mysql',
  'redis',
  'sqlite',
  'http',
  'jdbc',
  'cassandra',
  'neo4j',
  'elasticsearch',
  'qdrant',
  'influx',
] as const;

export class FdwRegistrationDto {
  @ApiPropertyOptional({ example: 'fdw' })
  @IsOptional()
  @IsString()
  foreign_schema?: string;

  @ApiPropertyOptional({ example: 'crm_contacts_ext' })
  @IsOptional()
  @IsString()
  foreign_table?: string;

  @ApiPropertyOptional({ example: 'crm_mysql_server' })
  @IsOptional()
  @IsString()
  server_name?: string;

  @ApiPropertyOptional({ example: { host: 'mysql', port: '3306', dbname: 'crm' } })
  @IsOptional()
  @IsObject()
  options?: Record<string, unknown>;

  @ApiPropertyOptional({ example: [{ name: 'id', type: 'text' }, { name: 'owner_id', type: 'text' }] })
  @IsOptional()
  columns?: Array<Record<string, unknown>>;
}

export class RegisterDatabaseDto {
  @ApiProperty({ example: 'postgresql', enum: REGISTERABLE_ENGINES })
  @IsEnum(REGISTERABLE_ENGINES)
  engine!: string;

  @ApiProperty({ example: 'my-production-db', minLength: 1, maxLength: 64 })
  @IsString()
  @IsNotEmpty()
  @MinLength(1)
  @MaxLength(64)
  name!: string;

  @ApiProperty({ example: 'postgresql://user:pass@host:5432/db' })
  @IsString()
  @IsNotEmpty()
  connection_string!: string;

  @ApiPropertyOptional({ default: false, description: 'Also register this external resource as a Postgres FDW alias.' })
  @IsOptional()
  @IsBoolean()
  register_via_fdw?: boolean;

  @ApiPropertyOptional({ type: FdwRegistrationDto })
  @IsOptional()
  @ValidateNested()
  @Type(() => FdwRegistrationDto)
  fdw?: FdwRegistrationDto;
}
