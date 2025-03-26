import React, { useState, useEffect } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Alert, AlertDescription } from '@/components/ui/alert';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Switch } from '@/components/ui/switch';
import { Label } from '@/components/ui/label';
import { 
  CheckCircle, 
  XCircle, 
  Trash2, 
  Plus, 
  RefreshCw, 
  LogOut,
  AlertCircle,
  ExternalLink
} from 'lucide-react';
import { useAuth } from './authContext';

const LightstackDashboard = () => {
  const { token, logout, apiUrl } = useAuth();
  const [activeStacks, setActiveStacks] = useState([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(null);
  const [activeJobs, setActiveJobs] = useState([]);
  const [activeTab, setActiveTab] = useState('add');
  const [isRefreshing, setIsRefreshing] = useState(false);

  const [formData, setFormData] = useState({
    phoenixd_domain: '',
    lnbits_domain: '',
    use_real_certs: false,
    use_postgres: false,
    email: ''
  });

  // Fetch active stacks
  const fetchStacks = async () => {
    try {
      setIsRefreshing(true);
      console.log('Fetching active stacks...');
      const response = await fetch(`${apiUrl}/stacks`, {
        headers: {
          'Authorization': `Bearer ${token}`
        }
      });
      if (!response.ok) throw new Error('Failed to fetch stacks');
      
      const responseText = await response.text();
      console.log('Stacks response:', responseText);
      
      const data = JSON.parse(responseText);
      console.log('Parsed stacks:', data);
      
      setActiveStacks(data);
      console.log('Active stacks updated:', data);
    } catch (err) {
      console.error('Error fetching stacks:', err);
      setError('Failed to fetch stacks: ' + err.message);
    } finally {
      setIsRefreshing(false);
    }
  };

  // Verifica se ci sono job attivi all'avvio
  useEffect(() => {
    fetchStacks();
    
    // Controlla se ci sono job salvati nel localStorage
    const savedJobsString = localStorage.getItem('lightstack_activeJobs');
    if (savedJobsString) {
      try {
        const savedJobs = JSON.parse(savedJobsString);
        console.log('Job recuperati dal localStorage:', savedJobs);
        
        if (Array.isArray(savedJobs) && savedJobs.length > 0) {
          setActiveJobs(savedJobs);
          
          // Riprendi il monitoraggio di ciascun job non completato
          savedJobs.forEach(job => {
            if (job.status !== 'completed' && job.status !== 'failed') {
              console.log(`Riprendendo monitoraggio job: ${job.id}`);
              monitorJobStatus(job.id);
            }
          });
        }
      } catch (e) {
        console.error("Errore nel recupero dei job salvati:", e);
        localStorage.removeItem('lightstack_activeJobs');
      }
    }
  }, [token]);

  // Salva i job attivi nel localStorage ad ogni cambiamento
  useEffect(() => {
    if (activeJobs.length > 0) {
      console.log('Salvataggio job nel localStorage:', activeJobs);
      localStorage.setItem('lightstack_activeJobs', JSON.stringify(activeJobs));
    } else {
      localStorage.removeItem('lightstack_activeJobs');
    }
  }, [activeJobs]);

  // Handle form input changes
  const handleInputChange = (e) => {
    const { name, value } = e.target;
    setFormData(prevState => ({
      ...prevState,
      [name]: value
    }));
  };

  // Handle toggle changes
  const handleToggleChange = (name) => {
    setFormData(prevState => ({
      ...prevState,
      [name]: !prevState[name]
    }));
  };

  // Funzione per monitorare lo stato del job
  const monitorJobStatus = async (jobId) => {
    try {
      let jobCompleted = false;
      let attempts = 0;
      const maxAttempts = 60; // 10 minuti con intervallo di 10s
      
      // Aggiungi il job alla lista dei job attivi se non esiste già
      setActiveJobs(prev => {
        if (!prev.some(j => j.id === jobId)) {
          return [...prev, { id: jobId, status: 'pending' }];
        }
        return prev;
      });
      
      while (!jobCompleted && attempts < maxAttempts) {
        attempts++;
        console.log(`[Job ${jobId}] Tentativo ${attempts}/${maxAttempts}`);
        
        await new Promise(resolve => setTimeout(resolve, 10000)); // Aspetta 10 secondi
        
        try {
          console.log(`[Job ${jobId}] Richiesta status al server...`);
          const response = await fetch(`${apiUrl}/jobs/${jobId}`, {
            headers: {
              'Authorization': `Bearer ${token}`
            }
          });
          
          if (!response.ok) {
            console.warn(`[Job ${jobId}] Risposta non valida: ${response.status}`);
            continue;
          }
          
          const responseText = await response.text();
          console.log(`[Job ${jobId}] Risposta: ${responseText}`);
          
          const jobData = JSON.parse(responseText);
          console.log(`[Job ${jobId}] Status: ${jobData.status}`);
          
          // Aggiorna lo stato del job nella lista
          setActiveJobs(prev => 
            prev.map(job => 
              job.id === jobId ? { ...job, status: jobData.status } : job
            )
          );
          
          if (jobData.status === 'completed') {
            console.log(`[Job ${jobId}] Completato con stack_id: ${jobData.stack_id}`);
            jobCompleted = true;
            
            // Forza aggiornamento stacks
            await fetchStacks();
            
            // Mostra messaggio di successo più evidente
            setSuccess(`Stack ${jobData.stack_id} creato con successo! Disponibile nella scheda "Manage Stacks".`);
            
            // Aggiorna il job con lo stack_id
            setActiveJobs(prev => 
              prev.map(job => 
                job.id === jobId ? { ...job, status: 'completed', stack_id: jobData.stack_id } : job
              )
            );
            
            // Cambia tab dopo un breve ritardo
            setTimeout(() => {
              setActiveTab('manage');
            }, 1000);
            
            break;
          } else if (jobData.status === 'failed') {
            jobCompleted = true;
            setError(`Stack creation failed: ${jobData.error || 'Unknown error'}`);
            
            // Aggiorna il job con l'errore
            setActiveJobs(prev => 
              prev.map(job => 
                job.id === jobId ? { ...job, status: 'failed', error: jobData.error } : job
              )
            );
            
            break;
          }
        } catch (error) {
          console.error(`[Job ${jobId}] Errore:`, error);
        }
      }
      
      if (!jobCompleted) {
        // Caso in cui il job è ancora in corso dopo tutti i tentativi
        console.log(`[Job ${jobId}] Limite tentativi raggiunto, si consiglia verifica manuale`);
        setSuccess('Stack creation is still in progress. Please check the Manage Stacks tab or refresh the page later.');
      }
      
      // In ogni caso, aggiorna la lista degli stack alla fine
      await fetchStacks();
    } catch (err) {
      console.error(`[Job ${jobId}] Errore nel monitoraggio:`, err);
      setError('Failed to monitor job status. Check Manage Stacks tab later.');
      await fetchStacks();
    }
  };

  // Handle stack addition
  const handleAddStack = async (e) => {
    e.preventDefault();
    setIsLoading(true);
    setError(null);
    setSuccess(null);
    
    try {
      // Invia la richiesta per creare lo stack
      console.log('Creating stack with data:', formData);
      const response = await fetch(`${apiUrl}/stacks`, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(formData)
      });

      console.log('Response status:', response.status);
      const responseText = await response.text();
      console.log('Response text:', responseText);

      if (!response.ok) {
        throw new Error(responseText || 'Failed to add stack');
      }
      
      const responseData = JSON.parse(responseText);
      console.log('Parsed response:', responseData);

      const jobId = responseData.job_id;
      
      // Mostra un messaggio informativo
      setSuccess('Stack creation started. This process may take several minutes. You will be notified when complete.');
      
      // Avvia il polling per controllare lo stato del job
      monitorJobStatus(jobId);
      
      // Resetta il form
      setFormData({
        phoenixd_domain: '',
        lnbits_domain: '',
        use_real_certs: false,
        use_postgres: false,
        email: ''
      });
    } catch (err) {
      console.error('Error in handleAddStack:', err);
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  // Handle stack removal
  const handleRemoveStack = async (stackId) => {
    if (!confirm('Are you sure you want to remove this stack? This action cannot be undone.')) {
      return;
    }

    setIsLoading(true);
    setError(null);
    setSuccess(null);
    
    try {
      console.log(`Removing stack ${stackId}...`);
      const response = await fetch(`${apiUrl}/stacks/${stackId}`, {
        method: 'DELETE',
        headers: {
          'Authorization': `Bearer ${token}`
        }
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.detail || 'Failed to remove stack');
      }

      console.log(`Stack ${stackId} removed successfully`);
      setActiveStacks(prev => prev.filter(stack => stack.id !== stackId));
      setSuccess('Stack removed successfully!');
      
      // Rimuovi anche eventuali job completati relativi a questo stack
      setActiveJobs(prev => prev.filter(job => job.stack_id !== stackId));
    } catch (err) {
      console.error(`Error removing stack ${stackId}:`, err);
      setError(err.message);
    } finally {
      setIsLoading(false);
    }
  };

  // Forza aggiornamento
  const handleForceRefresh = async () => {
    setSuccess("Aggiornamento in corso...");
    await fetchStacks();
    setSuccess("Lista stack aggiornata!");
  };

  // Ottieni lo stato di un job formattato per la visualizzazione
  const getJobStatusLabel = (status) => {
    switch (status) {
      case 'pending':
        return <span className="text-yellow-500 flex items-center"><RefreshCw className="mr-1 h-3 w-3 animate-spin" /> In attesa</span>;
      case 'running':
        return <span className="text-blue-500 flex items-center"><RefreshCw className="mr-1 h-3 w-3 animate-spin" /> In esecuzione</span>;
      case 'completed':
        return <span className="text-green-500 flex items-center"><CheckCircle className="mr-1 h-3 w-3" /> Completato</span>;
      case 'failed':
        return <span className="text-red-500 flex items-center"><XCircle className="mr-1 h-3 w-3" /> Fallito</span>;
      default:
        return <span>{status}</span>;
    }
  };

  // Rimuovi job completati
  const clearCompletedJobs = () => {
    setActiveJobs(prev => prev.filter(job => job.status !== 'completed' && job.status !== 'failed'));
  };

  return (
    <div className="container mx-auto p-4 max-w-4xl">
      <div className="flex justify-between items-center mb-4">
        <h1 className="text-2xl font-bold">Lightstack Management</h1>
        <div className="flex gap-2">
          <Button 
            variant="outline" 
            onClick={handleForceRefresh}
            disabled={isRefreshing}
          >
            <RefreshCw className={`mr-2 h-4 w-4 ${isRefreshing ? 'animate-spin' : ''}`} />
            Refresh
          </Button>
          <Button variant="outline" onClick={logout}>
            <LogOut className="mr-2 h-4 w-4" />
            Logout
          </Button>
        </div>
      </div>

      <Card>
        <CardContent className="p-6">
          <Tabs value={activeTab} onValueChange={setActiveTab}>
            <TabsList className="mb-4">
              <TabsTrigger value="add">Add Stack</TabsTrigger>
              <TabsTrigger value="manage">
                Manage Stacks
                {activeJobs.length > 0 && (
                  <span className="ml-2 bg-blue-500 text-white text-xs rounded-full px-2 py-1">
                    {activeJobs.filter(j => j.status === 'pending' || j.status === 'running').length}
                  </span>
                )}
              </TabsTrigger>
            </TabsList>

            <TabsContent value="add">
              <form onSubmit={handleAddStack} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="phoenixd_domain">Phoenixd Domain</Label>
                  <Input
                    id="phoenixd_domain"
                    name="phoenixd_domain"
                    placeholder="api.yourdomain.com"
                    value={formData.phoenixd_domain}
                    onChange={handleInputChange}
                    required
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor="lnbits_domain">LNbits Domain</Label>
                  <Input
                    id="lnbits_domain"
                    name="lnbits_domain"
                    placeholder="lnbits.yourdomain.com"
                    value={formData.lnbits_domain}
                    onChange={handleInputChange}
                    required
                  />
                </div>

                <div className="flex items-center space-x-2">
                  <Switch
                    id="use_real_certs"
                    checked={formData.use_real_certs}
                    onCheckedChange={() => handleToggleChange('use_real_certs')}
                  />
                  <Label htmlFor="use_real_certs">Use real Letsencrypt certificates</Label>
                </div>

                {formData.use_real_certs && (
                  <div className="space-y-2">
                    <Label htmlFor="email">Email for Letsencrypt</Label>
                    <Input
                      id="email"
                      name="email"
                      type="email"
                      placeholder="your@email.com"
                      value={formData.email}
                      onChange={handleInputChange}
                      required
                    />
                    <p className="text-sm text-gray-500">
                      This email will be used for important notifications about your SSL certificates.
                    </p>
                  </div>
                )}

                <div className="flex items-center space-x-2">
                  <Switch
                    id="use_postgres"
                    checked={formData.use_postgres}
                    onCheckedChange={() => handleToggleChange('use_postgres')}
                  />
                  <Label htmlFor="use_postgres">Use PostgreSQL</Label>
                </div>

                <Alert className="mt-4">
                  <AlertCircle className="h-4 w-4" />
                  <AlertDescription>
                    Make sure your domains are correctly configured and pointing to this server before adding a stack.
                  </AlertDescription>
                </Alert>

                <Button 
                  type="submit" 
                  className="w-full"
                  disabled={isLoading}
                >
                  {isLoading ? (
                    <>
                      <RefreshCw className="mr-2 h-4 w-4 animate-spin" />
                      Adding Stack...
                    </>
                  ) : (
                    <>
                      <Plus className="mr-2 h-4 w-4" />
                      Add Stack
                    </>
                  )}
                </Button>
              </form>

              {/* Mostra job attivi */}
              {activeJobs.length > 0 && (
                <div className="mt-6">
                  <div className="flex justify-between items-center mb-2">
                    <h3 className="text-lg font-medium">Active Jobs</h3>
                    {activeJobs.some(job => job.status === 'completed' || job.status === 'failed') && (
                      <Button 
                        variant="outline" 
                        size="sm"
                        onClick={clearCompletedJobs}
                      >
                        Clear Completed
                      </Button>
                    )}
                  </div>
                  <div className="space-y-2">
                    {activeJobs.map(job => (
                      <div key={job.id} className={`p-3 rounded-md border ${
                        job.status === 'completed' ? 'bg-green-50 border-green-200' : 
                        job.status === 'failed' ? 'bg-red-50 border-red-200' : 
                        'bg-gray-50 border-gray-200'
                      }`}>
                        <div className="flex justify-between items-center">
                          <div>
                            <span className="text-sm font-medium">Job: {job.id.substring(0, 8)}...</span>
                            {job.stack_id && (
                              <span className="ml-2 text-sm">Stack ID: {job.stack_id}</span>
                            )}
                          </div>
                          <div>{getJobStatusLabel(job.status)}</div>
                        </div>
                        {job.status === 'completed' && job.stack_id && (
                          <div className="mt-2 text-sm text-green-600">
                            Stack created successfully! 
                            <Button 
                              variant="link" 
                              size="sm" 
                              className="p-0 h-auto text-sm"
                              onClick={() => setActiveTab('manage')}
                            >
                              View in Manage Stacks
                            </Button>
                          </div>
                        )}
                        {job.status === 'failed' && job.error && (
                          <div className="mt-2 text-sm text-red-600">
                            Error: {job.error}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </TabsContent>

            <TabsContent value="manage">
              <div className="flex justify-between items-center mb-4">
                <h3 className="text-lg font-medium">Active Stacks</h3>
                <Button 
                  variant="outline" 
                  size="sm" 
                  onClick={fetchStacks}
                  disabled={isRefreshing}
                >
                  <RefreshCw className={`h-4 w-4 mr-2 ${isRefreshing ? 'animate-spin' : ''}`} />
                  Refresh Stacks
                </Button>
              </div>
              <div className="space-y-4">
                {activeStacks.length === 0 ? (
                  <div className="text-center py-8 text-gray-500">
                    No active stacks found. Add your first stack using the "Add Stack" tab.
                  </div>
                ) : (
                  activeStacks.map(stack => (
                    <Card key={stack.id} className="p-4">
                      <div className="flex justify-between items-start">
                        <div>
                          <h3 className="font-medium mb-1">Stack {stack.id}</h3>
                          <div className="text-sm text-gray-500 space-y-1">
                            <p>
                              <span className="font-medium">Phoenixd API:</span>{' '}
                              <a 
                                href={`https://${stack.phoenixd_domain}`} 
                                target="_blank" 
                                rel="noopener noreferrer"
                                className="text-blue-600 hover:underline inline-flex items-center"
                              >
                                {stack.phoenixd_domain}
                                <ExternalLink className="h-3 w-3 ml-1" />
                              </a>
                            </p>
                            <p>
                              <span className="font-medium">LNbits:</span>{' '}
                              <a 
                                href={`https://${stack.lnbits_domain}`} 
                                target="_blank" 
                                rel="noopener noreferrer"
                                className="text-blue-600 hover:underline inline-flex items-center"
                              >
                                {stack.lnbits_domain}
                                <ExternalLink className="h-3 w-3 ml-1" />
                              </a>
                            </p>
                          </div>
                        </div>
                        <Button
                          variant="destructive"
                          size="sm"
                          onClick={() => handleRemoveStack(stack.id)}
                          disabled={isLoading}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </Card>
                  ))
                )}
              </div>
              
              {/* Mostra job attivi anche nella tab di gestione */}
              {activeJobs.filter(job => job.status === 'pending' || job.status === 'running').length > 0 && (
                <div className="mt-6">
                  <h3 className="text-lg font-medium mb-2">Stacks in creazione</h3>
                  <div className="space-y-2">
                    {activeJobs
                      .filter(job => job.status === 'pending' || job.status === 'running')
                      .map(job => (
                        <div key={job.id} className="p-3 bg-gray-50 rounded-md border">
                          <div className="flex justify-between items-center">
                            <div>
                              <span className="text-sm font-medium">Job: {job.id.substring(0, 8)}...</span>
                            </div>
                            <div>{getJobStatusLabel(job.status)}</div>
                          </div>
                        </div>
                      ))
                    }
                  </div>
                </div>
              )}
            </TabsContent>
          </Tabs>

          {error && (
            <Alert variant="destructive" className="mt-4">
              <XCircle className="h-4 w-4" />
              <AlertDescription>{error}</AlertDescription>
            </Alert>
          )}

          {success && (
            <Alert className="mt-4">
              <CheckCircle className="h-4 w-4" />
              <AlertDescription>{success}</AlertDescription>
            </Alert>
          )}
        </CardContent>
      </Card>
    </div>
  );
};

export default LightstackDashboard;
