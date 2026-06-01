/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engines.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 23:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 23:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { QueryService, type EngineDescriptor } from './query.service';

/**
 * Public introspection endpoint — returns the engines this query-router
 * instance can dispatch to. Used by the M2 verify script and the SDK codegen
 * to discover available backends without parsing the source.
 */
@ApiTags('introspection')
@Controller('engines')
export class EnginesController {
  constructor(private readonly service: QueryService) {}

  @Get()
  @ApiOperation({
    summary: 'List engines registered with this query-router',
    description:
      'Returns the engine name (e.g. postgresql, mongodb, mysql, redis, http) and its capability descriptor (read/write/upsert/txIntra/stream) for each adapter currently mounted.',
  })
  list(): { engines: string[]; details: EngineDescriptor[] } {
    const details = this.service.listEngines();
    return { engines: details.map((d) => d.engine), details };
  }
}
