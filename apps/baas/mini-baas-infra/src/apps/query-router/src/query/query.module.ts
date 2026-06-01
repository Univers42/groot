/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.module.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HttpModule } from '@nestjs/axios';
import { QueryController } from './query.controller';
import { EnginesController } from './engines.controller';
import { QueryService } from './query.service';
import { OutboxService } from './outbox.service';
import { PostgresqlEngine } from '../engines/postgresql.engine';
import { MongodbEngine } from '../engines/mongodb.engine';
import { MysqlEngine } from '../engines/mysql.engine';
import { RedisEngine } from '../engines/redis.engine';
import { HttpEngine } from '../engines/http.engine';
import { JdbcEngine } from '../engines/jdbc.engine';
import { CassandraEngine } from '../engines/cassandra.engine';
import { Neo4jEngine } from '../engines/neo4j.engine';
import { ElasticsearchEngine } from '../engines/elasticsearch.engine';
import { QdrantEngine } from '../engines/qdrant.engine';
import { InfluxEngine } from '../engines/influx.engine';

@Module({
  imports: [ConfigModule, HttpModule],
  controllers: [QueryController, EnginesController],
  providers: [
    QueryService,
    OutboxService,
    PostgresqlEngine,
    MongodbEngine,
    MysqlEngine,
    RedisEngine,
    HttpEngine,
    JdbcEngine,
    CassandraEngine,
    Neo4jEngine,
    ElasticsearchEngine,
    QdrantEngine,
    InfluxEngine,
  ],
})
export class QueryModule {}
