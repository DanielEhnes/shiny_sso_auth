import logging 
from sqlalchemy import create_engine, event 
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.exc import SQLAlchemyError, IntegrityError, OperationalError
from contextlib import contextmanager

#logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class SQLiteHandler:
    """
    SQLiteHandler provides a small database access layer around SQLAlchemy.

    It creates a SQLite engine and a session factory, and exposes two context
    managers:
    
    - engine_scope(): opens a raw database connection and guarantees it is
      closed after use.
    
    - session_scope(): creates a SQLAlchemy session, commits on success, and
      rolls back on any error. It also logs common SQLAlchemy exceptions
      (IntegrityError, OperationalError, SQLAlchemyError) and always closes
      the session.

    The scopes ensures safe, consistent transaction handling and avoids
    repeating commit/rollback/close logic throughout the codebase.

    - return_engine(): Returns the engine itself.         
    """
    
    def __init__(self, db_url: str, echo: bool = True):
        self.engine = create_engine(db_url, echo=echo, future =True)
        self.SessionLocal = sessionmaker(bind=self.engine, expire_on_commit=False) 
        event.listens_for(self.engine, "connect", self.set_sqlite_pragma) 
        
    @staticmethod    
    def set_sqlite_pragma(conn, _):
        conn.exectue("PRAGMA foreign_keys = ON")
    
    def return_engine(self): 
        return self.engine
    
    @contextmanager 
    def engine_scope(self): 
        conn = self.engine.connect() 
        try: 
            yield conn 
        finally: 
            conn.close()
        
    @contextmanager
    def session_scope(self):
        session = self.SessionLocal()
        try:
            yield session
            session.commit()
            
        except IntegrityError as e:
            session.rollback() 
            logger.error("Integrity error during DB transaction: %s", str(e)) 
            raise
        
        except OperationalError as e: 
            session.rollback() 
            logger.error("Operational error (database unavailable or locked): %s", str(e)) 
            raise
        
        except SQLAlchemyError as e: 
            session.rollback() 
            logger.error("General SQLAlchemy error during DB transaction: %s", str(e)) 
            raise

        except Exception as e: 
            session.rollback() 
            logger.exception("Unexpected error during DB session.") 
            raise
            
        finally:
            session.close()
            