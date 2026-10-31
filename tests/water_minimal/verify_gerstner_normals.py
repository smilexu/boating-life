"""Small double-precision central-difference check of the actual shader P_DEG."""
import json, math
from pathlib import Path

root = Path(__file__).parent
state = json.loads((root / 'captures/water_repro_20261031_143746_684620.json').read_text())
w = state['water_shader_parameters']
def cross(a,b):
    return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def unit(a):
    l=math.sqrt(sum(v*v for v in a)); return [v/l for v in a]
def sample(x,z,t):
    p=[x,0,z]; dx=[1.,0,0]; dz=[0,0,1.]; old=[0.,0,0]
    n=int(w['WaveCount'])
    for i in range(n):
        s=w['WaveSteepnesses'][i]; a=w['WaveAmplitudes'][i]; f=w['WaveFrequencies'][i]
        d=math.radians(w['WaveDirectionsDegrees'][i]); ux,uz=math.sin(d),math.cos(d)
        k=math.tau*f; th=k*(ux*x+uz*z)+w['WaveSpeeds'][i]*(t+math.radians(w['WavePhases'][i]))
        sn,cs=math.sin(th),math.cos(th)
        disp=[s*a*ux*cs,s*sn,s*a*uz*cs]
        der=[-s*a*ux*sn,s*cs,-s*a*uz*sn]
        legacy=[-ux*f*a*cs,1-s*f*a*sn,-uz*f*a*cs]
        for j in range(3):
            p[j]+=disp[j]/n; dx[j]+=der[j]*k*ux/n; dz[j]+=der[j]*k*uz/n; old[j]+=legacy[j]/n
    return p,unit(cross(dz,dx)),unit(old)
def angle(a,b):
    return math.degrees(math.atan2(math.sqrt(sum(v*v for v in cross(a,b))),sum(x*y for x,y in zip(a,b))))
rows=[]
for x,z,t in [(12237.95,10059.49,9.628762),(12224,10059,9.628762),(0,0,0),(12300,10100,12)]:
    _,analytic,old=sample(x,z,t)
    for h in [.01,.001]:
        px=sample(x+h,z,t)[0]; mx=sample(x-h,z,t)[0]; pz=sample(x,z+h,t)[0]; mz=sample(x,z-h,t)[0]
        ref=unit(cross([(a-b)/(2*h) for a,b in zip(pz,mz)],[(a-b)/(2*h) for a,b in zip(px,mx)]))
        rows.append(dict(x=x,z=z,time=t,h=h,legacy_error_degrees=angle(old,ref),candidate_error_degrees=angle(analytic,ref)))
out=root/'captures/gerstner_normal_math.json'
out.write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))
