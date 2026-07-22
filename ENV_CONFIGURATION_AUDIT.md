# LIS Docker Environment Configuration Audit

## 📋 ENVIRONMENT VARIABLES CHECKLIST FOR PRODUCTION DEPLOYMENT

### Backend (lis-backend) - `.env.prod`

**Database Configuration** ✅
- `DB_CONNECTION=sqlsrv` (SQL Server, not MySQL)
- `DB_HOST=192.168.5.10` (Labcore database server)
- `DB_PORT=1433` (SQL Server default port)
- `DB_DATABASE=Labcore`
- `DB_USERNAME=sa`
- `DB_PASSWORD=Sistema2011`

**Application Configuration** ✅
- `APP_ENV=production`
- `APP_DEBUG=false` (disabled in production)
- `APP_KEY=base64:...` (Laravel encryption key, set)
- `LOG_LEVEL=info` (not debug)
- `BCRYPT_ROUNDS=12` (password hashing)

**Service URLs** ✅
- `LIS_MATCHER_BASE_URL=http://clinical-matcher:8001` (internal docker network)
- `LIS_MATCHER_ENABLED=true`
- `LIS_MATCHER_INTERNAL_TOKEN=lis-internal-prod-token-change-this` (⚠️ CHANGE THIS)

**Cache & Session** ✅
- `CACHE_STORE=database`
- `SESSION_DRIVER=database`
- `SESSION_ENCRYPT=true`
- `REDIS_HOST=redis` (Docker network)

**Security** ✅
- `CORS_ALLOWED_ORIGINS=http://frontend:3000,https://your-production-domain.com` (update domain)
- `COGNITO_HTTP_VERIFY_SSL=false` (for dev, enable in production)

**Sensitive Variables** ⚠️
- ✅ AWS credentials not hardcoded
- ✅ No `.env` file in Docker image (via .dockerignore)
- ❌ AWS_TEXTRACT credentials (empty, optional)

---

### Broker Gateway (lis-broker-gateway) - `.env.prod`

**Server Configuration** ✅
- `NODE_ENV=production`
- `PORT=3001` (matches Dockerfile EXPOSE)
- `LOG_LEVEL=info` (not debug)
- `REQUEST_TIMEOUT_MS=10000`

**Security** ⚠️
- `INTERNAL_API_KEY=change-me-in-production-at-least-32-characters` (⚠️ CHANGE THIS)

**Broker Configuration** ✅
- `BROKERS_ENABLED=traditum,imed,swiss-medical`
- `BROKER_SMG_API_KEY=c41f4e3d4ad9e74d6f69`
- `BROKER_SMG_EMAIL=integracionesapi130388@swissmedical.com.ar`
- `BROKER_SMG_PASSWORD=Swiss1234%`
- `BROKER_SMG_CUIT=30672372697`
- Retry logic enabled: `BROKER_SMG_RETRY_ATTEMPTS=2`
- Circuit breaker enabled: `BROKER_SMG_CIRCUIT_BREAKER_ENABLED=true`

**Service URLs** ✅
- `BACKEND_URL=http://backend:8000` (internal docker network)
- `SMG_BASE_URL=https://mobilepre.swissmedical.com.ar/pre/api-smg` (external)

---

### Clinical Matcher (lis-clinical-matcher) - `.env.prod`

**Application Configuration** ✅
- `APP_ENV=production`
- `LOG_LEVEL=info`
- `DEBUG=false`

**Service URLs** ✅
- `BACKEND_URL=http://backend:8000` (routes all DB requests through backend)
- `BACKEND_API_TOKEN=lis-internal-prod-token-change-this` (⚠️ CHANGE THIS)

**Server Configuration** ✅
- `HOST=0.0.0.0`
- `PORT=8001` (matches Dockerfile EXPOSE)
- `WORKERS=4` (multi-process Uvicorn)

**Feature Flags** ✅
- `ENABLE_OCR=true`
- `ENABLE_CACHING=true`

**Note:** ✅ **NO SQL SERVER DRIVERS NEEDED** — Routes through backend (no direct DB connection)

---

### Frontend (lis-front-monorepo) - `.env.prod`

**Cognito Authentication** ⚠️
- `NEXT_PUBLIC_COGNITO_DOMAIN=https://sa-east-1ugt0rhqcs.auth.sa-east-1.amazoncognito.com`
- `NEXT_PUBLIC_COGNITO_CLIENT_ID=5vddr7t8779ceneoksvra99930`
- `NEXT_PUBLIC_COGNITO_REDIRECT_URI=https://your-production-domain.com/auth/callback` (⚠️ UPDATE TO PROD DOMAIN)
- `NEXT_PUBLIC_COGNITO_LOGOUT_URI=https://your-production-domain.com/login` (⚠️ UPDATE)
- `NEXT_PUBLIC_COGNITO_SCOPE=openid email profile`

**API URLs** ✅
- `NEXT_PUBLIC_API_CORE_URL=http://backend:8000`
- `NEXT_PUBLIC_API_AUTH_URL=http://backend:8000`
- `NEXT_PUBLIC_API_CATALOG_URL=http://backend:8000`
- `NEXT_PUBLIC_API_BROKER_GATEWAY_URL=http://broker-gateway:3001`

**Build Configuration** ✅
- `NODE_ENV=production`
- `PORT=3000`
- `NEXT_PUBLIC_ENABLE_DOCUMENT_ANALYSIS=true`
- `NEXT_PUBLIC_ENABLE_CLINICAL_MATCHING=true`

**Note:** All `NEXT_PUBLIC_*` variables are exposed to browser (safe to do)

---

## 🔐 SECURITY CONSIDERATIONS

### ✅ Compliant
- Non-root users in all containers (www-data, node, app)
- No `.env` files copied to Docker images (.dockerignore set)
- SQL Server connection string NOT hardcoded in code
- External secrets (Cognito, Brokers) configured at runtime
- All services communicate via internal Docker network
- HEALTHCHECK configured for all services

### ⚠️ To Review Before Production
1. **Change these secrets** (currently using test/dev values):
   - `INTERNAL_API_KEY` (broker-gateway)
   - `LIS_MATCHER_INTERNAL_TOKEN` (backend)
   - `BACKEND_API_TOKEN` (clinical-matcher)

2. **Update domain-specific URLs**:
   - `NEXT_PUBLIC_COGNITO_REDIRECT_URI` → production domain
   - `NEXT_PUBLIC_COGNITO_LOGOUT_URI` → production domain
   - `CORS_ALLOWED_ORIGINS` → production domain

3. **Review Cognito configuration**:
   - Enable SSL verification: `COGNITO_HTTP_VERIFY_SSL=true` (when ready)
   - Validate user pool and client IDs match your AWS account

4. **Database connection**:
   - Verify SQL Server is accessible from Docker: `ping 192.168.5.10:1433`
   - Test with `docker-compose` before full deploy

5. **AWS Textract (optional)**:
   - Currently disabled. Enable only if you have AWS credentials
   - Provide AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY if needed

---

## 📦 docker-compose.prod.yml Configuration

**Services Included:**
✅ redis (cache, session storage)
✅ backend (PHP-FPM 8.3)
✅ broker-gateway (NestJS)
✅ frontend (Next.js)
✅ clinical-matcher (FastAPI)

**Network:** `lis-network` (bridge)

**Service Dependencies:**
```
redis
  ↓
backend (depends on redis)
  ↓
broker-gateway (depends on backend)
frontend (depends on backend)
clinical-matcher (depends on backend)
```

**Volumes:** All logs are persisted
```
redis-data
backend-logs
broker-logs
frontend-logs
matcher-logs
```

---

## 🚀 DEPLOYMENT CHECKLIST

- [ ] All 4 `.env.prod` files created in respective services
- [ ] SQL Server connection tested (192.168.5.10:1433)
- [ ] Change all `change-me-in-production` secrets
- [ ] Update Cognito redirect URIs to production domain
- [ ] Review CORS_ALLOWED_ORIGINS for production
- [ ] Test docker-compose build: `docker-compose -f docker-compose.prod.yml build`
- [ ] Test docker-compose up: `docker-compose -f docker-compose.prod.yml up`
- [ ] Verify all HEALTHCHECK endpoints respond
- [ ] Review logs in `/logs` volumes
- [ ] Load test with production traffic patterns

---

## 📝 NOTES

- **Database:** SQL Server (Labcore) at 192.168.5.10:1433
- **Authentication:** AWS Cognito (sa-east-1)
- **Brokers:** Traditum, IMED, Swiss Medical
- **Image Registry:** (set in deployment script if using Docker Hub/ECR)
- **Next.js:** Uses `standalone` output (optimized, ~150MB)
- **PHP:** Uses PHP-FPM on port 8000 (not php artisan serve)
- **FastAPI:** Uses Uvicorn with 4 workers

