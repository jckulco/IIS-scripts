# IIS-scripts
Useful scripts to automate tasks in IBM InfoSphere Information Server (RHEL)

a. Dar permisos de ejecución (777 a los tres archivos shell)
   1. chmod 777 1_configurar_servidor_iis.sh
   2. chmod 777 2_instalar_librerias_iis.sh
   3. chmod 777 3_variables_de_entorno_iis.sh

b. Ejecutar en orden
   1. 1_configurar_servidor_iis.sh
   2. 2_instalar_librerias_iis.sh
   3. 3_variables_de_entorno_iis.sh

c. Cuando se ejecute el script 2 (2_instalar_librerias_iis.sh), recomendable ejecutar en otra ventana del servidor:
   tail -f /var/log/dnf.log

d. Tras ejecutar correctamente, iniciar instalación de IBM InfoSphere Information Server
