/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.controller.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Body,
  Controller,
  Get,
  Headers,
  Param,
  ParseUUIDPipe,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { QueryService } from './query.service';
import { ExecuteQueryDto } from './dto/query.dto';
import type { Request } from 'express';

@ApiTags('query')
@Controller('query')
@UseGuards(AuthGuard)
export class QueryController {
  constructor(private readonly service: QueryService) {}

  @Post(':dbId/tables/:table')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiParam({ name: 'table', description: 'Table or collection name' })
  @ApiOperation({ summary: 'Execute a query on a registered database' })
  async execute(
    @CurrentUser() user: UserContext,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Param('table') table: string,
    @Body() dto: ExecuteQueryDto,
    @Headers('idempotency-key') idempotencyKey: string | undefined,
    @Req() request: Request,
  ) {
    if (idempotencyKey && !dto.idempotencyKey) dto.idempotencyKey = idempotencyKey;
    return this.service.executeQuery(dbId, table, user.id, dto, {
      requestId: request.requestId,
    });
  }

  @Get(':dbId/tables')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'List tables/collections in a registered database' })
  async listTables(
    @CurrentUser() user: UserContext,
    @Param('dbId', ParseUUIDPipe) dbId: string,
  ) {
    return this.service.listTables(dbId, user.id);
  }
}
