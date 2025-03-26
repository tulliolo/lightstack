from fastapi import FastAPI, HTTPException, Depends, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import List, Optional, Dict
import jwt
from datetime import datetime, timedelta
import subprocess
import os
import json
import re
import logging
import threading
import uuid
from pathlib import Path
from dotenv import load_dotenv

# Carica le variabili d'ambiente dal file .env
load_dotenv()

# Configurazione logging
logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

app = FastAPI(title="Lightstack UI API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configurazione
SECRET_KEY = os.getenv("JWT_SECRET_KEY")
if not SECRET_KEY:
    logger.error("JWT_SECRET_KEY non trovata nel file .env")
    raise ValueError("JWT_SECRET_KEY mancante")

ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30
# Modifica del percorso per l'installazione tradizionale
SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Configurazione utenti
ADMIN_USER = os.getenv("ADMIN_USER")
ADMIN_PASS = os.getenv("ADMIN_PASS")
if not ADMIN_USER or not ADMIN_PASS:
    logger.error("ADMIN_USER o ADMIN_PASS non trovati nel file .env")
    raise ValueError("Credenziali admin mancanti")

USERS_DB = {ADMIN_USER: ADMIN_PASS}

logger.debug(f"Utenti disponibili: {list(USERS_DB.keys())}")

# Classe per lo stato dei job
class JobStatus:
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"

# Dizionario per tenere traccia dei job
job_tracker: Dict[str, Dict] = {}

# Modelli
class Token(BaseModel):
    access_token: str
    token_type: str

class TokenData(BaseModel):
    username: Optional[str] = None

class User(BaseModel):
    username: str

class UserInDB(User):
    password: str

class Stack(BaseModel):
    phoenixd_domain: str
    lnbits_domain: str
    use_real_certs: bool = False
    use_postgres: bool = False
    email: Optional[str] = None

class StackResponse(BaseModel):
    id: str
    phoenixd_domain: str
    lnbits_domain: str

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")

# Funzione per eseguire la creazione dello stack in un thread separato
def run_stack_creation_thread(job_id: str, stack: Stack, input_data: str):
    try:
        job_tracker[job_id]["status"] = JobStatus.RUNNING
        
        process = subprocess.run(
            [os.path.join(SCRIPT_DIR, "init.sh"), "add"],
            input=input_data,
            capture_output=True,
            text=True,
            cwd=SCRIPT_DIR
        )
        
        logger.debug(f"Process stdout:\n{process.stdout}")
        logger.debug(f"Process stderr:\n{process.stderr}")
        
        if process.returncode != 0:
            logger.error(f"Stack creation failed: {process.stdout}\n{process.stderr}")
            job_tracker[job_id]["status"] = JobStatus.FAILED
            job_tracker[job_id]["error"] = process.stderr or "Failed to create stack"
            return
        
        # Estrai l'ID dello stack dal risultato
        stack_id = None
        for line in process.stdout.splitlines():
            if "stack_" in line:
                match = re.search(r"stack_(\d+)", line)
                if match:
                    stack_id = match.group(1)
                    break
        
        if not stack_id:
            job_tracker[job_id]["status"] = JobStatus.FAILED
            job_tracker[job_id]["error"] = "Failed to extract stack ID"
            return
        
        # Aggiorna lo stato del job
        job_tracker[job_id]["status"] = JobStatus.COMPLETED
        job_tracker[job_id]["stack_id"] = stack_id
        
        logger.info(f"Stack creation completed for job {job_id}, stack_id: {stack_id}")
    except Exception as e:
        logger.error(f"Error in run_stack_creation_thread: {str(e)}")
        job_tracker[job_id]["status"] = JobStatus.FAILED
        job_tracker[job_id]["error"] = str(e)

# Funzioni di gestione nginx
def manage_nginx(action: str):
    """Gestisce l'avvio/stop di nginx usando systemd"""
    try:
        if action == "stop":
            logger.info("Stopping nginx service...")
            subprocess.run(["systemctl", "stop", "nginx"], check=True)
            return True
        elif action == "start":
            logger.info("Starting nginx service...")
            subprocess.run(["systemctl", "start", "nginx"], check=True)
            return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Error managing nginx service: {str(e)}")
        return False

# Funzioni di autenticazione
def verify_password(plain_password: str, username: str) -> bool:
    stored_password = USERS_DB.get(username)
    if not stored_password:
        return False
    return plain_password == stored_password

def get_user(username: str) -> Optional[UserInDB]:
    if username in USERS_DB:
        return UserInDB(username=username, password=USERS_DB[username])
    return None

def authenticate_user(username: str, password: str) -> Optional[UserInDB]:
    logger.debug(f"Tentativo autenticazione per utente: {username}")
    user = get_user(username)
    if not user:
        logger.debug("Utente non trovato")
        return None
    if not verify_password(password, username):
        logger.debug("Password non corretta")
        return None
    logger.debug("Autenticazione riuscita")
    return user

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None):
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + timedelta(minutes=15)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

async def get_current_user(token: str = Depends(oauth2_scheme)) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        if username is None:
            raise credentials_exception
        token_data = TokenData(username=username)
    except jwt.PyJWTError:
        raise credentials_exception
    user = get_user(token_data.username)
    if user is None:
        raise credentials_exception
    return user

# Endpoints
@app.post("/token", response_model=Token)
async def login_for_access_token(form_data: OAuth2PasswordRequestForm = Depends()):
    logger.debug(f"Tentativo di login con username: {form_data.username}")
    user = authenticate_user(form_data.username, form_data.password)
    if not user:
        logger.debug("Autenticazione fallita")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    logger.debug("Autenticazione riuscita, genero token")
    access_token_expires = timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    access_token = create_access_token(
        data={"sub": user.username}, expires_delta=access_token_expires
    )
    return {"access_token": access_token, "token_type": "bearer"}

@app.get("/stacks", response_model=List[StackResponse])
async def get_stacks(current_user: User = Depends(get_current_user)):
    try:
        logger.debug(f"Using init script at: {os.path.join(SCRIPT_DIR, 'init.sh')}")
        result = subprocess.run(
            [os.path.join(SCRIPT_DIR, 'init.sh'), "list"],
            capture_output=True,
            text=True,
            check=True,
            cwd=SCRIPT_DIR
        )
        
        stacks = []
        for line in result.stdout.strip().split('\n'):
            try:
                if line.startswith("{"):  # Solo le linee che iniziano con {
                    stack_data = json.loads(line)
                    stacks.append(stack_data)
            except json.JSONDecodeError:
                # Ignora silenziosamente le righe che non sono JSON valido
                continue
                
        return stacks
    except subprocess.CalledProcessError as e:
        logger.error(f"Error listing stacks: {e.stderr}")
        raise HTTPException(status_code=500, detail=e.stderr)

@app.post("/stacks")
async def add_stack(stack: Stack, current_user: User = Depends(get_current_user)):
    try:
        logger.debug(f"Adding new stack with config: {stack.dict()}")
        if stack.use_real_certs:
            logger.info("Real certificates requested, reconfiguring nginx")
            try:
                subprocess.run(["nginx", "-s", "reload"], check=True)
            except subprocess.CalledProcessError as e:
                logger.error(f"Failed to reconfigure nginx: {e}")
                raise HTTPException(status_code=500, detail="Failed to reconfigure nginx")

        # Crea l'input per lo script
        input_data = f"""{stack.phoenixd_domain}
{stack.lnbits_domain}
{"y" if stack.use_real_certs else "n"}
{"y" if stack.use_postgres else "n"}
{stack.email if stack.use_real_certs else ""}
y
y
"""
        logger.debug(f"Input data exactly as sent to script:\n[START]\n{input_data}[END]")
        
        # Genera un ID per il job
        job_id = str(uuid.uuid4())
        
        # Inizializza il job nel tracker
        job_tracker[job_id] = {
            "status": JobStatus.PENDING,
            "stack": stack.dict(),
            "stack_id": None,
            "error": None,
            "created_at": datetime.utcnow().isoformat()
        }
        
        # Avvia il processo in un thread separato
        thread = threading.Thread(
            target=run_stack_creation_thread,
            args=(job_id, stack, input_data)
        )
        thread.daemon = True
        thread.start()
        
        # Rispondi subito con l'ID del job
        return {
            "job_id": job_id,
            "status": JobStatus.PENDING,
            "message": "Stack creation started. Check job status to monitor progress."
        }
    except Exception as e:
        logger.error(f"Error creating stack: {str(e)}")
        if stack.use_real_certs:
            try:
                subprocess.run(["nginx", "-s", "reload"], check=True)
            except:
                pass
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/jobs/{job_id}")
async def get_job_status(job_id: str, current_user: User = Depends(get_current_user)):
    if job_id not in job_tracker:
        raise HTTPException(status_code=404, detail="Job not found")
    
    job = job_tracker[job_id]
    
    response = {
        "job_id": job_id,
        "status": job["status"]
    }
    
    if job["status"] == JobStatus.COMPLETED:
        response["stack_id"] = job["stack_id"]
    elif job["status"] == JobStatus.FAILED:
        response["error"] = job["error"]
    
    return response

@app.delete("/stacks/{stack_id}")
async def remove_stack(stack_id: str, current_user: User = Depends(get_current_user)):
    try:
        logger.debug(f"Removing stack {stack_id}")
        script_path = os.path.join(SCRIPT_DIR, "init.sh")
        
        # Controlla quanti stack sono attivi
        list_process = subprocess.run(
            [script_path, "list"],
            capture_output=True,
            text=True,
            cwd=SCRIPT_DIR
        )
        
        # Conta gli stack attivi (le righe che iniziano con un numero)
        active_stacks = len([line for line in list_process.stdout.splitlines() 
                           if line.strip() and line[0].isdigit()])
        logger.debug(f"Found {active_stacks} active stacks")

        # Input diverso basato sul numero di stack
        input_data = "y\n" if active_stacks == 1 else f"{stack_id}\ny\n"
        logger.debug(f"Using input data: {input_data}")
        
        process = subprocess.run(
            [script_path, "del"],
            input=input_data,
            capture_output=True,
            text=True,
            cwd=SCRIPT_DIR,
            env={
                "PATH": os.environ["PATH"],
                "SCRIPT_DIR": SCRIPT_DIR
            }
        )
        
        logger.debug(f"Command stdout: {process.stdout}")
        logger.debug(f"Command stderr: {process.stderr}")
        
        if process.returncode != 0:
            raise HTTPException(
                status_code=500, 
                detail=process.stderr or "Failed to remove stack"
            )
            
        stack_path = os.path.join(SCRIPT_DIR, f"stack_{stack_id}")
        if os.path.exists(stack_path):
            raise HTTPException(
                status_code=500, 
                detail="Stack removal incomplete"
            )
            
        return {"message": f"Stack {stack_id} removed successfully"}
        
    except Exception as e:
        logger.error(f"Error removing stack: {str(e)}")
        logger.exception("Stack trace:")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    return {"status": "healthy"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8005)

